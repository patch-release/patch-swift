// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
@testable import CodeGenerator
import ViewNodeIR

/// STRUCTURAL before/after measurement of the bare-identifier color/font-token hazard.
/// Lowers every corpus view and counts the color/font HOST TOKENS whose SOURCE is a single
/// BARE IDENTIFIER (`backgroundView`, `makeBackground`) — exactly the shape that, before
/// the type-provability gate, the thunk emitted as `.color(<bare>)`/`.font(<bare>)` (a
/// compile error whenever the bare name wasn't a `Color`/`Font`). After the gate, such a
/// token is only recorded for a PROVABLY-typed bare name; an unknown bare name native-slots,
/// so this count drops to (essentially) zero. Env-gated (PATCH_THUNK_CORPUS=1); CI skips.
final class SwiftUIBareTokenMeasureTests: XCTestCase {

    func testBareIdentifierColorFontTokensInCorpus() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PATCH_THUNK_CORPUS"] == "1",
                          "set PATCH_THUNK_CORPUS=1 to run the corpus bare-token measurement")
        let root = ProcessInfo.processInfo.environment["PATCH_CORPUS_ROOT"]
            ?? CorpusPaths.defaultRepos
        let fm = FileManager.default
        guard let apps = try? fm.contentsOfDirectory(atPath: root) else {
            throw XCTSkip("corpus root not found: \(root)")
        }

        var bareColorFontTokens: [(app: String, file: String, kind: String, source: String)] = []
        var totalColorFontTokens = 0
        var viewFiles = 0

        for app in apps.sorted() {
            let appDir = root + "/" + app
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: appDir, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let en = fm.enumerator(atPath: appDir) else { continue }
            for case let rel as String in en where rel.hasSuffix(".swift") {
                if rel.contains("/.build/") || rel.contains("/Pods/")
                    || rel.contains("/Carthage/") || rel.contains("DerivedData") { continue }
                let path = appDir + "/" + rel
                guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
                guard text.contains("var body: some View") else { continue }
                viewFiles += 1
                let views = BodyLowering().lowerAllViews(source: text, sameFileThunk: true)
                for v in views {
                    for tok in v.hostTokens where tok.kind == .color || tok.kind == .font {
                        totalColorFontTokens += 1
                        let s = tok.source.trimmingCharacters(in: .whitespaces)
                        if Self.isBareIdentifier(s) {
                            bareColorFontTokens.append((app, rel, "\(tok.kind)", s))
                        }
                    }
                }
            }
        }

        print("=== CORPUS BARE-IDENTIFIER COLOR/FONT TOKEN MEASURE ===")
        print("view-files scanned: \(viewFiles); color/font tokens: \(totalColorFontTokens)")
        print("BARE-IDENTIFIER color/font tokens (the .color(some View) hazard): \(bareColorFontTokens.count)")
        for t in bareColorFontTokens.prefix(80) {
            print("  • \(t.app)/\(t.file)  \(t.kind)(\(t.source))")
        }
    }

    /// A single bare Swift identifier — letters/digits/underscore, starting with a letter or
    /// underscore, no dots/calls/operators/whitespace. (A `Theme.Colors.ink` member access is
    /// NOT bare; a `.red` leading-dot is NOT bare either.)
    static func isBareIdentifier(_ s: String) -> Bool {
        guard let first = s.first, first.isLetter || first == "_" else { return false }
        return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}
