import XCTest
@testable import PatchSDK
import PatchViewIR
#if canImport(SwiftUI)
@testable import PatchSwiftUI
#endif

// PerfHostsideTransparencyTests — PERF batch (perf-hostside-batch).
// =================================================================
// Proves the two SHIPPED host-side render optimizations are BYTE-FOR-BYTE transparent
// (#1 the parse-free flat-JSON merge) and behaviorally identical (#3 the WASM export-
// handle cache). These are the #1 false-RENDER-risk area: a merge that produced a
// different-but-equivalent string would feed a different render-cache key (cache miss
// or, worse, key divergence), so every assertion here is an EXACT-STRING diff of the
// fast path against the original JSONSerialization path (`mergeViaJSONSerialization`).
//
// (#2 — the hand-rolled flat emission decoder — was deliberately NOT shipped; the
// emission IR surface (201 Modifier cases + 91 NodeKind cases + 47 Codable types, 4
// indirect/recursive enums, IR already at v8 and growing every coverage release) is too
// large/volatile for a hand decoder to be PROVABLY exhaustive — a future-added case
// would silently mis-decode → wrong tree → wrong render. See the progress report.)

#if canImport(SwiftUI)
final class PerfHostsideTransparencyTests: XCTestCase {

    // MARK: - #1 Parse-free merge: byte-for-byte identical to the JSONSerialization path

    /// The core transparency invariant: for ANY pair of inputs, the production `merge`
    /// (fast path + fallback) MUST equal `mergeViaJSONSerialization` (the proven oracle)
    /// byte-for-byte. Run across a large corpus of flat, nested, escaped, numeric-edge,
    /// and malformed inputs — every shape the merge sees in production plus adversarial
    /// edges that MUST take the fallback.
    func testMergeIsByteIdenticalToJSONSerializationOracle() {
        // Each entry is merged against EVERY other entry (both directions) so base/override
        // roles are both exercised, and a flat input is paired with nested/escaped ones.
        let corpus: [String] = [
            // --- flat scalar (the fast path) ---
            #"{"a":1,"b":"x"}"#,
            #"{"b":"y"}"#,
            #"{"name":"Ada","count":0}"#,
            #"{"count":5}"#,
            #"{"soundOn":false,"badge":3}"#,
            #"{"flag":true,"nothing":null}"#,
            #"{"z":1,"a":2,"m":3}"#,                       // unsorted keys → must sort
            #"{"id":9007199254740993}"#,                   // > 2^53 integer
            #"{"neg":-42,"zero":0,"negzero":-0}"#,         // -0 canonicalizes to 0
            #"{"f":1.5,"g":1.0,"h":0.10,"i":1e3,"j":2.5e-3,"k":1E2}"#, // float reformatting
            #"{"pi":3.141592653589793}"#,
            #"{}"#,                                         // empty object
            #"{ "spaced" : 1 , "ws" : "yes" }"#,           // whitespace between tokens
            #"{"emoji":"héllo ☃","plain":"abc"}"#,         // non-ASCII (no escapes) → fast path OK
            // --- nested / arrays (MUST take the fallback) ---
            #"{"obj":{"x":1,"a":2},"y":3}"#,               // nested object (re-sorted by slow path)
            #"{"arr":[1,2,3],"k":"v"}"#,                   // array value
            #"{"deep":{"b":{"c":1}},"t":"u"}"#,
            #"{"mixed":[{"q":1}],"s":2}"#,
            // --- escaped strings (MUST take the fallback: canonical form rewrites them) ---
            #"{"slash":"a\/b"}"#,                           // \/ → / under canonical (fallback)
            #"{"uni":"\u0041"}"#,                  // \u0041 -> "A" under canonical (fallback)
            #"{"tabbed":"a\tb","nl":"x\ny"}"#,             // control escapes
            #"{"q":"he said \"hi\""}"#,                     // escaped quote (this one IS canonical)
            #"{"back":"a\\b"}"#,                            // escaped backslash (canonical)
            // --- malformed numbers (JSONSerialization REJECTS → merge returns the other side) ---
            #"{"a":00}"#,                                   // leading zero (invalid JSON)
            #"{"a":01}"#,                                   // leading zero (invalid JSON)
            #"{"a":+5}"#,                                   // leading + (invalid)
            #"{"a":.5}"#,                                   // bare fraction (invalid)
            #"{"a":5.}"#,                                   // trailing dot (invalid)
            #"{"a":1.2.3}"#,                                // double dot (invalid)
            #"{"a":1e}"#,                                   // empty exponent (invalid)
            #"{"a":5abc}"#,                                 // trailing junk (invalid)
            // --- malformed / edge (MUST fall back; oracle defines the result) ---
            #"not json"#,
            #"{"unterminated":"#,
            #"[]"#,                                         // top-level array, not object
            #"{"dup":1,"dup":2}"#,                          // duplicate key
            #"   "#,                                        // whitespace only
            "",                                            // empty string (special-cased)
        ]

        var pairsChecked = 0
        for base in corpus {
            for over in corpus {
                let fast = PatchFlatJSON.merge(base: base, override: over)
                let oracle = PatchFlatJSON.mergeViaJSONSerialization(base: base, override: over)
                XCTAssertEqual(fast, oracle,
                    "merge diverged from the JSONSerialization oracle:\n  base=\(base)\n  over=\(over)\n  fast=\(fast)\n  oracle=\(oracle)")
                pairsChecked += 1
            }
        }
        XCTAssertGreaterThan(pairsChecked, 800, "corpus should exercise a large cross-product")
    }

    /// Production-shaped inputs: real props JSON (sorted scalars from `buildJSON`) ∪ a
    /// guest scalar state ∪ an input-token JSON — the exact three-way merge `body` runs.
    /// All flat ⇒ all take the fast path ⇒ must still equal the oracle.
    func testProductionShapedMergeMatchesOracle() {
        let props = #"{"badgeCount":3,"displayName":"Ada","notificationsOn":true}"#
        let guest = #"{"badgeCount":7}"#
        let token = #"{"__numtok_radius":12,"__strtok_label":"Pro"}"#

        let m1 = PatchFlatJSON.merge(base: props, override: guest)
        XCTAssertEqual(m1, PatchFlatJSON.mergeViaJSONSerialization(base: props, override: guest))
        let m2 = PatchFlatJSON.merge(base: m1, override: token)
        XCTAssertEqual(m2, PatchFlatJSON.mergeViaJSONSerialization(base: m1, override: token))
        // The override genuinely won and keys are sorted (cache-key stable).
        XCTAssertTrue(m2.contains(#""badgeCount":7"#))
        XCTAssertTrue(m2.contains(#""__numtok_radius":12"#))
    }

    /// The fast path must be DETERMINISTIC and stable across key-insertion order — the
    /// render cache keys on the exact string, so the same logical merge must always
    /// produce the same bytes regardless of input key order.
    func testMergeOutputIsKeyOrderStable() {
        let a = PatchFlatJSON.merge(base: #"{"a":1,"b":2,"c":3}"#, override: #"{"d":4}"#)
        let b = PatchFlatJSON.merge(base: #"{"c":3,"a":1,"b":2}"#, override: #"{"d":4}"#)
        let c = PatchFlatJSON.merge(base: #"{"b":2,"c":3,"a":1}"#, override: #"{"d":4}"#)
        XCTAssertEqual(a, b)
        XCTAssertEqual(b, c)
        XCTAssertEqual(a, #"{"a":1,"b":2,"c":3,"d":4}"#)
    }

    /// Number canonicalization must match the slow path exactly (the #1 splice hazard):
    /// `1.0`→`1`, `1e3`→`1000`, `0.10`→`0.1`, `-0`→`0`, large ints kept exact.
    func testNumberCanonicalizationMatchesOracle() {
        let cases = [
            #"{"a":1.0}"#, #"{"a":1e3}"#, #"{"a":0.10}"#, #"{"a":-0}"#,
            #"{"a":1.50}"#, #"{"a":2.5e-3}"#, #"{"a":1E2}"#,
            #"{"a":9007199254740993}"#, #"{"a":-9007199254740993}"#,
            #"{"a":3.141592653589793}"#,
        ]
        for c in cases {
            let fast = PatchFlatJSON.merge(base: c, override: #"{"b":1}"#)
            let oracle = PatchFlatJSON.mergeViaJSONSerialization(base: c, override: #"{"b":1}"#)
            XCTAssertEqual(fast, oracle, "number \(c) canonicalized differently")
        }
    }

    /// A large integer @State (> 2^53) must survive byte-exact (regression guard for
    /// BUG #73 / R2-#98 — the fast path must NOT route it through a lossy Double).
    func testLargeIntSurvivesFastMerge() {
        let big: Int64 = 9_007_199_254_740_993
        let merged = PatchFlatJSON.merge(base: "{\"id\":\(big)}", override: #"{"other":1}"#)
        XCTAssertTrue(merged.contains("\(big)"), "large int lost precision: \(merged)")
        XCTAssertEqual(merged, PatchFlatJSON.mergeViaJSONSerialization(base: "{\"id\":\(big)}", override: #"{"other":1}"#))
    }

    // MARK: - #3 WASM export-handle cache: same results, repeated lookups elided

    /// A cached function/memory handle must return the SAME resolved export on every
    /// call, and a NEGATIVE lookup must stay negative — the cache may not invent or
    /// drop an export. Verified through a real activated runtime.
    func testHandleCacheReturnsStableResults() throws {
        guard let url = Bundle.module.url(forResource: "EngineSettingsView", withExtension: "wasm") else {
            throw XCTSkip("EngineSettingsView.wasm fixture missing")
        }
        // Activate through Patch so the host-bridge imports the fixture needs are linked,
        // then reach into the active WASMRuntime to exercise the handle cache directly.
        let patch = Patch()
        patch.bridges.registerDefaults()
        try patch.activate(bytes: [UInt8](try Data(contentsOf: url)))
        try patch.withRuntime { runtime in
            // A known-present export: stable handle across repeated lookups.
            let name = runtime.hasFunction("view_body") ? "view_body" : "patch_malloc"
            XCTAssertTrue(runtime.hasFunction(name))
            let f1 = try runtime.function(name)
            let f2 = try runtime.function(name)
            XCTAssertEqual(f1, f2, "cached function handle must be identical across calls")

            // A known-absent export: negative cache must stay negative.
            XCTAssertFalse(runtime.hasFunction("definitely_not_an_export_zzz"))
            XCTAssertFalse(runtime.hasFunction("definitely_not_an_export_zzz")) // second hit = neg-cache
            XCTAssertThrowsError(try runtime.function("definitely_not_an_export_zzz"))

            // Memory resolves and stays the same handle.
            let m1 = try runtime.memory()
            let m2 = try runtime.memory()
            XCTAssertEqual(m1, m2, "cached memory handle must be identical across calls")
        }
    }

    /// End-to-end: repeated `callPacked` invocations against the cached-handle runtime
    /// produce identical output bytes to the first call (the cache changes timing, never
    /// results). Also implicitly proves the cached memory handle observes guest writes.
    func testCallPackedResultsUnchangedWithHandleCache() throws {
        guard let url = Bundle.module.url(forResource: "EngineSettingsView", withExtension: "wasm") else {
            throw XCTSkip("EngineSettingsView.wasm fixture missing")
        }
        let patch = Patch()
        patch.bridges.registerDefaults()
        try patch.activate(bytes: [UInt8](try Data(contentsOf: url)))
        let bodyExport = patch.hasFunction("view_body") ? "view_body" : "view_body__SettingsView"
        let input = [UInt8](#"{"badgeCount":3,"displayName":"Ada","notificationsOn":true}"#.utf8)

        let first = try patch.callPacked(bodyExport, input)
        for _ in 0..<25 {
            let again = try patch.callPacked(bodyExport, input)
            XCTAssertEqual(again, first, "callPacked output changed across repeated calls (handle cache must not alter results)")
        }
        XCTAssertFalse(first.isEmpty)
    }
}
#endif
