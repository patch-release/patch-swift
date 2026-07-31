// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
@testable import CodeGenerator
@testable import Compiler
@testable import PartitioningEngine

/// MEASUREMENT (breakthrough #6): how many additional functions become
/// fusion-eligible on a networking-heavy app once the `URLSession` request/response
/// surface is wired into the FusionRewriter's rewriteable set.
///
/// This reproduces the production engine's `BuildPipeline.fusionEligibleByFile`
/// predicate (a function is fusion-eligible iff it is not already pure-eligible, not
/// genuinely native, has ≥1 native hit, and EVERY native hit is fusion-rewriteable),
/// run twice over the same `CoverageReport`: with the networking symbols EXCLUDED
/// (the pre-#6 baseline) vs INCLUDED (post-#6). The delta is #6's measured unlock.
///
/// Skips when the real cloned corpus is absent (CI has no corpus), so it never
/// blocks CI; run locally with the corpus present to print the numbers.
final class NetworkingFusionMeasurementTests: XCTestCase {

    /// The networking symbol #6 adds to the rewriteable set. ONLY `URLSession`:
    /// `data(from:)` is the v1 fusion target. `URLRequest` is NOT added (it is absent
    /// in the WASM-SDK guest Foundation), so a function building a `URLRequest` cannot
    /// be fusion'd — it stays BRIDGED (ships OTA native), just not decode-in-WASM. The
    /// measured unlock is therefore the bare-GET request/response value logic.
    static let networkingSymbols: Set<String> = ["URLSession"]

    private func corpusRoot() throws -> URL {
        let candidates = [
            ProcessInfo.processInfo.environment["PATCH_CORPUS"],
            CorpusPaths.defaultRepos,
        ].compactMap { $0 }
        for c in candidates {
            let u = URL(fileURLWithPath: c, isDirectory: true)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        throw XCTSkip("corpus not present (set PATCH_CORPUS to measure)")
    }

    /// Count fusion-eligible functions under a given rewriteable symbol set —
    /// the exact predicate `BuildPipeline.fusionEligibleByFile` applies.
    private func fusionEligibleCount(_ report: CoverageReport, rewriteable: Set<String>) -> Int {
        var n = 0
        for r in report.results {
            if r.classification == .wasmEligible { continue }
            if r.classification == .native { continue }
            guard !r.nativeHits.isEmpty,
                  r.nativeHits.allSatisfy({ rewriteable.contains($0.symbol) }) else { continue }
            n += 1
        }
        return n
    }

    func testNetworkingUnlockOnNetworkingHeavyApps() throws {
        let root = try corpusRoot()
        let engine = PartitioningEngine()
        // The post-#6 rewriteable set (what the production pipeline now ships).
        let withNet = BuildPipeline.fusionRewriteableSymbols
        // The pre-#6 baseline: same set MINUS the networking symbols.
        let withoutNet = withNet.subtracting(Self.networkingSymbols)
        XCTAssertTrue(Self.networkingSymbols.isSubset(of: withNet),
                      "the production rewriteable set must include the #6 networking symbols")

        let apps = ["Get", "Moya", "Alamofire", "IceCubesApp", "NetNewsWire"]
        var anyMeasured = false
        var totalDelta = 0
        print("\n=== Breakthrough #6 networking fusion unlock (production engine) ===")
        print("(URLSession.data(from:) GET unlock; functions building a URLRequest stay")
        print(" BRIDGED — URLRequest is absent in the WASM-SDK guest Foundation.)")
        print(String(format: "%-14@ %8@ %8@ %8@ %8@", "app" as NSString, "funcs" as NSString,
                     "pre#6" as NSString, "post#6" as NSString, "+unlock" as NSString))
        for app in apps {
            let dir = root.appendingPathComponent(app)
            guard FileManager.default.fileExists(atPath: dir.path) else { continue }
            guard let report = try? engine.analyze(directory: dir) else { continue }
            anyMeasured = true
            let total = report.results.count
            let before = fusionEligibleCount(report, rewriteable: withoutNet)
            let after = fusionEligibleCount(report, rewriteable: withNet)
            let delta = after - before
            totalDelta += delta
            print(String(format: "%-14@ %8d %8d %8d %8d",
                         app as NSString, total, before, after, delta))
        }
        print("===================================================================\n")
        XCTAssertTrue(anyMeasured, "at least one networking app must be measured")
        // The honest claim: wiring `URLSession` into the fusion set unlocks NET-NEW
        // fusion-eligible functions across the networking corpus (the bare-GET decode
        // layer). Functions wrapped in a URLRequest stay bridged (correctly).
        XCTAssertGreaterThan(totalDelta, 0,
            "#6 must unlock additional bare-GET fusion-eligible functions across the networking corpus")
    }
}
