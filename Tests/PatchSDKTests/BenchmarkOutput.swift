// SPDX-License-Identifier: MIT

import Foundation

/// Where the perf/benchmark harnesses drop their raw-number and report files.
///
/// These suites are measurement harnesses, not assertions — they write a text
/// report next to their numbers so a run can be diffed against a previous one.
/// The destination is machine-independent: set `PATCH_BENCH_OUT` to keep the
/// reports somewhere durable, otherwise they land under the system temp dir so
/// a checkout on any machine can run them without touching a fixed home path.
enum BenchmarkOutput {

    /// Root directory for benchmark artifacts (`$PATCH_BENCH_OUT`, else temp).
    static var root: String {
        if let override = ProcessInfo.processInfo.environment["PATCH_BENCH_OUT"],
           !override.isEmpty {
            return override
        }
        return (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("patch-benchmarks")
    }

    /// A named sub-directory of `root` (created on demand by the caller).
    static func directory(_ name: String) -> String {
        (root as NSString).appendingPathComponent(name)
    }
}
