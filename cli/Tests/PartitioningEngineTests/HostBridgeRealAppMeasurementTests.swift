// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
@testable import PartitioningEngine
@testable import CodeGenerator
@testable import Compiler

// ===========================================================================
// LEVER #2 — the REAL-APP COVERAGE-LIFT MEASUREMENT.
//
// Runs the host-bridge ROUTING + RE-LOWER pass (`HostBridgeLowering`) over real
// corpus apps and reports, per app:
//   * forced-native functions the pass examined,
//   * routed call sites (unique content-addressed symbols),
//   * functions that FLIPPED native→OTA (the re-split — the headline number).
//
// This is the analysis half of `patchcli build` with `PATCH_HOST_BRIDGE=1` (no
// WASM compile — the routing + re-lower is a pure-analysis + codegen pass), so it
// measures the SAME native→routed lift the real build produces, fast and
// deterministically. Gated behind `PATCH_HB_MEASURE=1` so it does NOT run in CI
// (it needs the local-only corpus); when the corpus is absent it skips.
//
// HONESTY: a "lowered" count is a function whose rewritten body PARSES + carries a
// spliced routed sequence — the demote-safe re-split. The on-device `have()`/
// `.error` fallback + the build-time thunk-typecheck net are the further nets; this
// counts the ENGINE-side flip (native→guest-body-carrying-a-routed-call), which is
// exactly what "Lever #2 moves coverage" means.
// ===========================================================================
final class HostBridgeRealAppMeasurementTests: XCTestCase {

    /// The corpus lives at the repo root (gitignored, local-only). Resolved
    /// relative to this source file's path up to the repo, then `corpus/repos`,
    /// with `PATCH_CORPUS` / `PATCH_CORPUS_ROOT` as overrides. Nil when absent.
    private func corpusRoot() -> URL? {
        CorpusPaths.resolvedRoot()
    }

    func testMeasureRealAppCoverageLift() throws {
        guard ProcessInfo.processInfo.environment["PATCH_HB_MEASURE"] == "1" else {
            throw XCTSkip("set PATCH_HB_MEASURE=1 to run the real-app measurement")
        }
        guard let corpus = corpusRoot() else {
            throw XCTSkip("corpus not found (local-only)")
        }

        // A focused slate of real apps with genuine forced-native business logic.
        // Each is a Swift package / app with @objc/UIKit/own-type calls — the
        // forced-native bucket Lever #2 targets. (Env override: PATCH_HB_APPS=a,b,c.)
        let apps: [String]
        if let override = ProcessInfo.processInfo.environment["PATCH_HB_APPS"] {
            apps = override.split(separator: ",").map(String.init)
        } else {
            apps = ["Alamofire", "Kingfisher", "Nuke", "SwiftDate", "Moya",
                    "MessageKit", "RxSwift", "KeychainAccess", "Money",
                    "PhoneNumberKit", "SQLite.swift", "Files", "Get", "Hue"]
        }

        var totalExamined = 0, totalRouted = 0, totalLowered = 0
        var appsWithLift = 0
        var lines: [String] = []
        lines.append(String(format: "%-18@ %10@ %8@ %9@", "APP" as NSString,
                            "forced-nat" as NSString, "routed" as NSString,
                            "LOWERED" as NSString))

        for app in apps {
            let dir = corpus.appendingPathComponent(app)
            guard FileManager.default.fileExists(atPath: dir.path) else { continue }
            // Find the source root: prefer Sources/, else the repo dir itself.
            let sourcesDir = dir.appendingPathComponent("Sources")
            let sourceRoot = FileManager.default.fileExists(atPath: sourcesDir.path) ? sourcesDir : dir

            let report: CoverageReport
            do {
                report = try PartitioningEngine().analyze(directory: sourceRoot)
            } catch {
                lines.append("\(app): analyze failed (\(error))")
                continue
            }

            let buildDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("hb-measure-\(app)-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: buildDir) }

            // Run the pass WITHOUT the thunk-typecheck net (no host-swiftc dependency
            // per-app; the synthetic suite proves the net keeps a type-correct thunk).
            let r: HostBridgeLowering.Result
            do {
                r = try HostBridgeLowering(moduleName: app.replacingOccurrences(of: ".", with: "_"))
                    .run(report: report, sourceDir: sourceRoot, buildDir: buildDir,
                         runThunkTypecheck: false)
            } catch {
                lines.append("\(app): lowering failed (\(error))")
                continue
            }

            let uniqueRouted = Set(r.routed.map(\.symbol.id)).count
            totalExamined += r.examinedForcedNativeFunctions
            totalRouted += uniqueRouted
            totalLowered += r.lowered.count
            if r.lowered.count > 0 { appsWithLift += 1 }
            lines.append(String(format: "%-18@ %10d %8d %9d", app as NSString,
                                r.examinedForcedNativeFunctions, uniqueRouted, r.lowered.count))
            // Name a few lowered functions per app for the report.
            for l in r.lowered.prefix(3) {
                lines.append("    ↳ LOWER \(l.functionID) (\(l.routedCallCount) routed call(s))")
            }
        }

        lines.append("")
        lines.append("TOTAL forced-native examined: \(totalExamined)")
        lines.append("TOTAL routed symbols:         \(totalRouted)")
        lines.append("TOTAL functions LOWERED (native→OTA): \(totalLowered)  across \(appsWithLift) app(s)")

        let report = lines.joined(separator: "\n")
        print("\n===== LEVER #2 REAL-APP COVERAGE-LIFT MEASUREMENT =====\n\(report)\n")
        // Write the report next to the worktree for the agent to read.
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("hb-measure-report.txt")
        try? report.write(to: out, atomically: true, encoding: .utf8)
        print("(report written to \(out.path))")
    }
}
