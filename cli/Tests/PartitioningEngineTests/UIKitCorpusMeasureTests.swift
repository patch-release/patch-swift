// SPDX-License-Identifier: Apache-2.0

// UIKitCorpusMeasureTests — a local-only measurement probe (NOT a CI gate): scan the
// real 77-app corpus's UIKit cell/VC construction sites and report how many lower vs
// demote, so the "milk-more" coverage lift is grounded in real source, not synthetics.
// Gated behind PATCH_UIKIT_CORPUS_MEASURE=1 (the corpus is gitignored / absent in CI).
//
// This measures PER-METHOD (not per-file): a file can declare several cells/VCs, each
// lowering or demoting independently (`diagnoseAllCells`). The bail reason is bucketed
// to its leading phrase; with PATCH_UIKIT_SNIPPETS=1 it also prints one example demote
// per bucket (type + method + reason) so the residual can be classified by hand:
// reachable-lever vs genuine imperative friction vs binary-symbol wall.

import XCTest
import Foundation
@testable import CodeGenerator

final class UIKitCorpusMeasureTests: XCTestCase {

    func testMeasureCorpusLowering() throws {
        guard ProcessInfo.processInfo.environment["PATCH_UIKIT_CORPUS_MEASURE"] == "1" else {
            throw XCTSkip("set PATCH_UIKIT_CORPUS_MEASURE=1 to run the local corpus measure")
        }
        let root = ProcessInfo.processInfo.environment["PATCH_CORPUS_ROOT"]
            ?? CorpusPaths.defaultRepos
        let snippets = ProcessInfo.processInfo.environment["PATCH_UIKIT_SNIPPETS"] == "1"
        let fm = FileManager.default
        guard fm.fileExists(atPath: root) else { throw XCTSkip("corpus not present at \(root)") }

        let lowering = UIKitCellLowering()
        var filesScanned = 0
        var loweredMethods = 0
        var demotedMethods = 0
        var cellLowered = 0, cellDemoted = 0, vcLowered = 0, vcDemoted = 0
        var bailReasons: [String: Int] = [:]
        // One example per bucket: "Type.method @ relpath : full reason".
        var examples: [String: [String]] = [:]

        let en = fm.enumerator(atPath: root)
        while let rel = en?.nextObject() as? String {
            guard rel.hasSuffix(".swift") else { continue }
            let path = root + "/" + rel
            guard let data = fm.contents(atPath: path),
                  let src = String(data: data, encoding: .utf8) else { continue }
            // Cheap pre-filter: a cell/VC base + a construction-ish method.
            guard src.contains(": UITableViewCell") || src.contains(": UICollectionViewCell")
                    || src.contains(": UIViewController") || src.contains(": UIView")
                    || src.contains(": UITableViewHeaderFooterView")
                    || src.contains(": UICollectionReusableView") else { continue }
            guard src.contains("addSubview") || src.contains("addArrangedSubview") else { continue }

            let diags = lowering.diagnoseAllCells(source: src)
            guard !diags.isEmpty else { continue }
            filesScanned += 1
            for d in diags {
                if d.lowered {
                    loweredMethods += 1
                    if d.containerKind == .cell { cellLowered += 1 } else { vcLowered += 1 }
                } else {
                    demotedMethods += 1
                    if d.containerKind == .cell { cellDemoted += 1 } else { vcDemoted += 1 }
                    let phrase = d.reason.split(separator: ":").first.map(String.init) ?? d.reason
                    bailReasons[phrase, default: 0] += 1
                    if snippets, (examples[phrase]?.count ?? 0) < 4 {
                        examples[phrase, default: []].append("\(d.typeName).\(d.methodName) @ \(rel)\n      → \(d.reason)")
                    }
                }
            }
        }

        let total = loweredMethods + demotedMethods
        let pct = total > 0 ? Double(loweredMethods) / Double(total) * 100 : 0
        print("=== UIKit corpus measure (PER-METHOD) ===")
        print("files scanned: \(filesScanned)   candidate methods: \(total)")
        print("LOWERED: \(loweredMethods)  DEMOTED: \(demotedMethods)  (\(String(format: "%.1f", pct))% lower)")
        print("  cells:  \(cellLowered) lowered / \(cellDemoted) demoted")
        print("  VC/View:\(vcLowered) lowered / \(vcDemoted) demoted")
        print("--- demote reasons (all) ---")
        for (reason, n) in bailReasons.sorted(by: { $0.value > $1.value }) {
            print("  \(n)\t\(reason)")
        }
        if snippets {
            print("--- example demotes per bucket ---")
            for (reason, n) in bailReasons.sorted(by: { $0.value > $1.value }) {
                print("### [\(n)] \(reason)")
                for ex in examples[reason] ?? [] { print("    \(ex)") }
            }
        }
    }
}
