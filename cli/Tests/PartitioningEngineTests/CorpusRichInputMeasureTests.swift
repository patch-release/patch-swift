// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
@testable import CodeGenerator

/// MEASUREMENT-ONLY (skipped unless PATCH_CORPUS_DIR is set): lowers every SwiftUI
/// source file in a corpus tree and counts views that now classify a `.flatStruct` /
/// `.enumValue` input (the rich-input coverage win). NOT a pass/fail correctness gate —
/// it prints a tally so the dev can quantify how many real same-file struct/enum-input
/// views newly lower. (Production lowering is PER-FILE, so only a model type DEFINED IN
/// THE SAME FILE as the view is in the catalog — matching the existing `.structArray` path.)
final class CorpusRichInputMeasureTests: XCTestCase {
    func testMeasureRichInputLoweringAcrossCorpus() throws {
        guard let root = ProcessInfo.processInfo.environment["PATCH_CORPUS_DIR"] else {
            throw XCTSkip("set PATCH_CORPUS_DIR to a corpus tree to measure")
        }
        let fm = FileManager.default
        var flatStructViews: [String] = []
        var enumViews: [String] = []
        var bothFiles = Set<String>()
        let en = fm.enumerator(at: URL(fileURLWithPath: root),
                               includingPropertiesForKeys: nil)
        while let u = en?.nextObject() as? URL {
            guard u.pathExtension == "swift",
                  let src = try? String(contentsOf: u, encoding: .utf8),
                  src.contains(": View"), src.contains("body") else { continue }
            // Cheap pre-filter: must have both a struct/enum def AND a view in the file.
            for lowered in BodyLowering().lowerAllViews(source: src) {
                for inp in lowered.inputs {
                    if inp.kind == .flatStruct {
                        flatStructViews.append("\(lowered.viewName).\(inp.name): \(inp.structElement?.typeName ?? "?")")
                        bothFiles.insert(u.lastPathComponent)
                    } else if inp.kind == .enumValue {
                        enumViews.append("\(lowered.viewName).\(inp.name): \(inp.enumElement?.typeName ?? "?")")
                        bothFiles.insert(u.lastPathComponent)
                    }
                }
            }
        }
        print("=== CORPUS RICH-INPUT MEASUREMENT (\(root)) ===")
        print("flatStruct inputs that LOWER (\(flatStructViews.count)):")
        for v in flatStructViews.sorted() { print("  [struct] \(v)") }
        print("enumValue inputs that LOWER (\(enumViews.count)):")
        for v in enumViews.sorted() { print("  [enum]   \(v)") }
        print("total views newly lowering a rich input: \(flatStructViews.count + enumViews.count) across \(bothFiles.count) files")
    }
}
