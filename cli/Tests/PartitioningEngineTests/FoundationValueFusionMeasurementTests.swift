// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
@testable import CodeGenerator
@testable import Compiler
@testable import PartitioningEngine

/// MEASUREMENT — the Foundation VALUE bridges (Date clock / ISO8601 string<->date).
///
/// These APIs are `wasmSafeFoundation`: a function using them already classifies
/// `wasmEligible`, but it carries a **T2 Foundation tier blocker** (it pulls ICU), so
/// it ships at the ~11.7 MB Foundation tier. The FusionRewriter rewrites the call site
/// to a `patch_host.*` host import; the rewritten source no longer references the
/// formatter/`Date()`, so `EmbeddedCompatibility` drops it to **T0** (tens of KB) —
/// the host shell does the real Foundation/ICU work.
///
/// This asserts the BEFORE→AFTER tier change directly (the realized win), plus the
/// eligibility-stays-eligible invariant, and optionally measures the tier drop on the
/// real corpus (skipped when absent — never blocks CI).
final class FoundationValueFusionMeasurementTests: XCTestCase {

    private let compat = EmbeddedCompatibility()
    private let rewriter = FusionRewriter()

    // MARK: - The honest before/after: T2 (native form) -> T0 (fused form)

    /// `Date().timeIntervalSince1970` is a pure-`Double` value at T0 once fused —
    /// the rewritten source has no `Date` token, so it drops out of T2.
    func testDateNowDropsToT0AfterFusion() {
        let src = """
        func nowSeconds() -> Double {
            return Date().timeIntervalSince1970
        }
        """
        // `Date` is a bridged-Foundation value, so the source itself is already T0 per
        // analyzeSource (Date is in bridgedFoundationValues, not a blocker) — but the
        // REAL compile needs `Date` in-module (embedded has none). After fusion the
        // shim is pure Double, so the rewritten source is unambiguously T0 with NO
        // Foundation symbol at all.
        let r = rewriter.rewrite(src)
        XCTAssertTrue(r.didRewrite)
        XCTAssertFalse(r.source.contains("Date("), "the Date() clock read must be lowered")
        XCTAssertEqual(compat.analyzeSource(r.source).tier, .t0Embedded)
    }

    /// `ISO8601DateFormatter` is a HARD T2 blocker in the native form; after fusion the
    /// formatter token is gone and the source is T0 (the host does the ISO8601 work).
    func testISO8601FormatterDropsFromT2ToT0AfterFusion() {
        let src = """
        func stamp(_ d: Date) -> String {
            return ISO8601DateFormatter().string(from: d)
        }
        """
        // BEFORE: the native form pulls ISO8601DateFormatter -> T2 (ICU).
        let before = compat.analyzeSource(src)
        XCTAssertEqual(before.tier, .t2Foundation,
                       "ISO8601DateFormatter is a T2 (ICU) blocker before fusion")
        XCTAssertTrue(before.blockers.contains { $0.contains("ISO8601DateFormatter") })

        // AFTER: the rewriter lowers the call; no formatter token remains.
        let r = rewriter.rewrite(src)
        XCTAssertTrue(r.bridgedLeaves.contains("ISO8601DateFormatter().string(from:)"))
        XCTAssertFalse(r.source.contains("ISO8601DateFormatter"))
        // The rewritten body still mentions `Date` (the arg type) — a bridged value,
        // NOT a blocker — so the verdict is T0.
        XCTAssertEqual(compat.analyzeSource(r.source).tier, .t0Embedded,
                       "after fusion the formatter is gone -> T0 (host does the ICU work)")
    }

    func testISO8601ParseDropsFromT2ToT0AfterFusion() {
        let src = """
        func parse(_ s: String) -> Date? {
            return ISO8601DateFormatter().date(from: s)
        }
        """
        XCTAssertEqual(compat.analyzeSource(src).tier, .t2Foundation)
        let r = rewriter.rewrite(src)
        XCTAssertFalse(r.source.contains("ISO8601DateFormatter"))
        XCTAssertEqual(compat.analyzeSource(r.source).tier, .t0Embedded)
    }

    // MARK: - LEVER #2: the SettingsScreen.relativeString T2 -> T0 drop

    /// The concrete real-app target. The `RelativeDateTimeFormatter` builder is a HARD
    /// T2 (ICU) blocker before fusion; after the builder is collapsed to the host
    /// `relative_date_format` shim, no formatter token remains → T0.
    func testRelativeStringBuilderDropsFromT2ToT0AfterFusion() {
        let src = """
        func relativeString(from date: Date) -> String {
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .abbreviated
            return f.localizedString(for: date, relativeTo: .now)
        }
        """
        // BEFORE: RelativeDateTimeFormatter is now a registered T2 (ICU) blocker.
        let before = compat.analyzeSource(src)
        XCTAssertEqual(before.tier, .t2Foundation,
                       "RelativeDateTimeFormatter pulls ICU → T2 before fusion")
        XCTAssertTrue(before.blockers.contains { $0.contains("RelativeDateTimeFormatter") })

        // AFTER: the builder is gone; the body is pure (the `Date` arg is a bridged value).
        let r = rewriter.rewrite(src)
        XCTAssertTrue(r.bridgedLeaves.contains("RelativeDateTimeFormatter.localizedString(for:relativeTo:)"))
        XCTAssertFalse(r.source.contains("RelativeDateTimeFormatter"))
        XCTAssertEqual(compat.analyzeSource(r.source).tier, .t0Embedded,
                       "after fusion the formatter is gone -> T0 (host does the ICU work)")
    }

    /// `Calendar.current.startOfDay(for:)` is a T2 Calendar blocker before fusion; the
    /// one-liner rewrite removes the `Calendar` token → T0.
    func testCalendarStartOfDayDropsFromT2ToT0AfterFusion() {
        let src = """
        func midnight(_ d: Date) -> Date {
            return Calendar.current.startOfDay(for: d)
        }
        """
        XCTAssertEqual(compat.analyzeSource(src).tier, .t2Foundation)
        let r = rewriter.rewrite(src)
        XCTAssertTrue(r.bridgedLeaves.contains("Calendar.current.startOfDay(for:)"))
        // The `Calendar.current` API token is gone (the shim NAME contains "Calendar",
        // which is fine — it's not the blocker `Calendar` identifier); the tier is the
        // authoritative check. `analyzeSource` matches `Calendar` as a whole identifier,
        // and `_patchFusionCalendarStartOfDay` is a single identifier, not `Calendar`.
        XCTAssertFalse(r.source.contains("Calendar.current"),
                       "the Calendar.current API call must be lowered; got:\n\(r.source)")
        XCTAssertEqual(compat.analyzeSource(r.source).tier, .t0Embedded,
                       "after fusion no `Calendar` identifier remains -> T0")
    }

    // MARK: - LEVER: Regex — the T2 (ICU) -> T0 drop

    /// `NSRegularExpression` is a HARD T2 (ICU) blocker before fusion; after the bare
    /// member-call form is rewritten to the host `regex_*` shim, no `NSRegularExpression`
    /// token remains → T0 (the shell does the real ICU regex work).
    func testNSRegexCountDropsFromT2ToT0AfterFusion() {
        let src = """
        func digitGroups(in text: String) -> Int {
            return NSRegularExpression(pattern: "[0-9]+").numberOfMatches(in: text, range: NSRange(location: 0, length: text.count))
        }
        """
        let before = compat.analyzeSource(src)
        XCTAssertEqual(before.tier, .t2Foundation,
                       "NSRegularExpression pulls ICU → T2 before fusion")
        XCTAssertTrue(before.blockers.contains { $0.contains("NSRegularExpression") })

        let r = rewriter.rewrite(src)
        XCTAssertTrue(r.bridgedLeaves.contains("NSRegularExpression.numberOfMatches"))
        XCTAssertFalse(r.source.contains("NSRegularExpression"),
                       "the ICU type token must be gone; got:\n\(r.source)")
        XCTAssertEqual(compat.analyzeSource(r.source).tier, .t0Embedded,
                       "after fusion no NSRegularExpression token remains -> T0")
    }

    /// The `str.range(of: pat, options: .regularExpression)` validation form: the source
    /// has no `NSRegularExpression` TYPE token, so `analyzeSource` already sees no ICU
    /// blocker — but the REAL compile needs ICU for the `.regularExpression` option. After
    /// fusion the regex op is a host call, so the rewritten source is unambiguously T0
    /// with no regex surface at all (the same "already-T0-by-token but really-T2-at-compile
    /// -> genuinely-T0-after-fusion" shape as the `Date().timeIntervalSince1970` clock).
    func testRangeRegexTestIsT0AfterFusion() {
        let src = """
        func isValidEmail(_ s: String) -> Bool {
            return s.range(of: "^[^@]+@[^@]+\\\\.[^@]+$", options: .regularExpression) != nil
        }
        """
        let r = rewriter.rewrite(src)
        XCTAssertTrue(r.didRewrite)
        XCTAssertTrue(r.bridgedLeaves.contains("String.range(of:options:.regularExpression)"))
        XCTAssertFalse(r.source.contains(".regularExpression"),
                       "the regex-option op must be lowered; got:\n\(r.source)")
        XCTAssertEqual(compat.analyzeSource(r.source).tier, .t0Embedded)
    }

    /// A function whose only regex touch is the `.regularExpression` String form
    /// classifies `wasmEligible` (the option/`NSRegularExpression` are wasm-safe
    /// Foundation) — the bridge changes its TIER (T2->T0 at compile), never eligibility.
    func testRegexValidatorClassifiesEligible() throws {
        let dir = try makeProject([
            "Validate.swift": """
            import Foundation
            struct Validate {
                func email(_ s: String) -> Bool {
                    s.range(of: "^[^@]+@[^@]+$", options: .regularExpression) != nil
                }
                func clean(_ s: String) -> String {
                    s.replacingOccurrences(of: "[^a-z]+", with: "-", options: .regularExpression)
                }
            }
            """,
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let report = try PartitioningEngine().analyze(directory: dir)
        for name in ["email", "clean"] {
            let result = report.results.first { $0.functionID.contains(".\(name)(") }
            let cls = try XCTUnwrap(result, "missing classification for \(name)").classification
            XCTAssertNotEqual(cls, .native,
                              "\(name) uses only a wasm-safe regex API -> must NOT be native")
            XCTAssertEqual(cls, .wasmEligible,
                           "\(name) is pure value logic over a wasm-safe regex op -> wasmEligible")
        }
    }

    // MARK: - Eligibility stays eligible (the classifier sees no native hit)

    /// A function whose only Foundation touch is one of these value APIs classifies
    /// `wasmEligible` — the bridge changes its TIER (T2->T0), never its eligibility.
    func testFunctionUsingDateValueAPIsClassifiesEligible() throws {
        let dir = try makeProject([
            "Stamp.swift": """
            import Foundation
            struct Stamp {
                func epoch() -> Double { Date().timeIntervalSince1970 }
                func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }
                func back(_ s: String) -> Date? { ISO8601DateFormatter().date(from: s) }
            }
            """,
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let report = try PartitioningEngine().analyze(directory: dir)
        for name in ["epoch", "iso", "back"] {
            let result = report.results.first { $0.functionID.contains(".\(name)(") }
            let cls = try XCTUnwrap(result, "missing classification for \(name)").classification
            XCTAssertNotEqual(cls, .native,
                              "\(name) uses only a Foundation VALUE API -> must NOT be native")
            XCTAssertEqual(cls, .wasmEligible,
                           "\(name) is pure value logic over a wasm-safe Foundation value -> wasmEligible")
        }
    }

    /// A struct method whose only Foundation touch is `RelativeDateTimeFormatter` /
    /// `Calendar.current` math classifies `wasmEligible` (these are wasmSafeFoundation
    /// value APIs). The fusion changes its TIER (T2->T0), not its eligibility — exactly
    /// the `SettingsScreen.relativeString` real-app shape.
    func testRelativeAndCalendarMethodsClassifyEligible() throws {
        let dir = try makeProject([
            "DateStuff.swift": """
            import Foundation
            struct DateStuff {
                func relativeString(from date: Date) -> String {
                    let f = RelativeDateTimeFormatter()
                    f.unitsStyle = .abbreviated
                    return f.localizedString(for: date, relativeTo: .now)
                }
                func midnight(_ d: Date) -> Date { Calendar.current.startOfDay(for: d) }
                func sameDay(_ a: Date, _ b: Date) -> Bool { Calendar.current.isDate(a, inSameDayAs: b) }
            }
            """,
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let report = try PartitioningEngine().analyze(directory: dir)
        for name in ["relativeString", "midnight", "sameDay"] {
            let result = report.results.first { $0.functionID.contains(".\(name)(") }
            let cls = try XCTUnwrap(result, "missing classification for \(name)").classification
            XCTAssertNotEqual(cls, .native,
                              "\(name) uses only a wasm-safe Foundation value API -> must NOT be native")
            XCTAssertEqual(cls, .wasmEligible,
                           "\(name) is pure value logic over wasm-safe Foundation -> wasmEligible")
        }
    }

    // MARK: - Corpus tier-drop measurement (skipped when corpus absent)

    func testTierDropOnCorpus() throws {
        let root = try corpusRoot()
        // A broad sweep — measure where the Foundation VALUE rewriter actually fires on
        // real source, and (for the files whose ONLY remaining blocker is the bridged
        // date-value API) the realized T2 -> T0 drop.
        let apps = try FileManager.default
            .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map { $0.lastPathComponent }
            .sorted()
        var filesFired = 0          // real files where ≥1 date-value leaf was lowered
        var leafFireCounts: [String: Int] = [:]  // per-leaf activation count
        var soleBlockerFiles = 0    // files whose only tier blocker is the date-value API
        var droppedTier = 0         // of those, how many actually dropped a tier
        print("\n=== Foundation VALUE bridge — corpus activation + tier drop ===")
        var anyMeasured = false
        for app in apps {
            let dir = root.appendingPathComponent(app)
            anyMeasured = true
            let swifts = (try? swiftFiles(in: dir)) ?? []
            for f in swifts {
                guard let src = try? String(contentsOf: f, encoding: .utf8) else { continue }
                let r = rewriter.rewrite(src)
                let dateLeaves = r.bridgedLeaves.intersection(Self.dateValueLeafIDs)
                guard !dateLeaves.isEmpty else { continue }
                filesFired += 1
                for leaf in dateLeaves { leafFireCounts[leaf, default: 0] += 1 }
                // Realized tier drop only when the date-value API is the SOLE blocker.
                if usesOnlyBridgedDateValueAPI(src) {
                    let before = compat.analyzeSource(src).tier
                    if before == .t2Foundation {
                        soleBlockerFiles += 1
                        if compat.analyzeSource(r.source).tier < before { droppedTier += 1 }
                    }
                }
            }
        }
        print("  real corpus files with ≥1 date-value leaf lowered: \(filesFired)")
        for leaf in Self.dateValueLeafIDs.sorted() {
            print(String(format: "    %-42@ fired in %3d file(s)",
                         leaf as NSString, leafFireCounts[leaf] ?? 0))
        }
        print("  files whose SOLE tier blocker is ISO8601 (T2->T0 candidates): \(soleBlockerFiles)")
        print("  of those, dropped a tier after fusion: \(droppedTier)")
        print("================================================================\n")
        XCTAssertTrue(anyMeasured, "at least one corpus app must be measured")
        // The honest claim: the Date-clock leaf fires on real corpus source (the
        // dominant single-expression date-value form). ISO8601 one-liners are rarer
        // (apps reuse a configured formatter), which the per-leaf breakdown shows.
        XCTAssertGreaterThan(filesFired, 0,
            "the Foundation VALUE rewriter must fire on real corpus source")
    }

    /// The leaf ids this pass added (for the per-leaf corpus activation breakdown).
    static let dateValueLeafIDs: Set<String> = [
        "Date().timeIntervalSince1970", "Date().timeIntervalSinceNow",
        "ISO8601DateFormatter().string(from:)", "ISO8601DateFormatter().date(from:)",
        // LEVER #2: Date/Calendar/Formatter leaves.
        "RelativeDateTimeFormatter.localizedString(for:relativeTo:)",
        "Calendar.current.startOfDay(for:)", "Calendar.current.isDate(_:inSameDayAs:)",
    ]

    // MARK: - Helpers

    /// True iff the file's tier blockers are EXACTLY a subset of the date-value APIs
    /// this pass bridges (ISO8601DateFormatter + Date) — i.e. the rewrite is the sole
    /// reason a tier could drop. Conservative: any OTHER blocker -> excluded.
    private func usesOnlyBridgedDateValueAPI(_ src: String) -> Bool {
        let v = compat.analyzeSource(src)
        guard !v.blockers.isEmpty else { return false }
        // Only count files whose blockers are all ISO8601/Date* AND that contain a form
        // our rewriter actually lowers (so the measurement is honest).
        let allOurs = v.blockers.allSatisfy { b in
            b.contains("ISO8601DateFormatter")
        }
        let hasRewriteableForm = src.contains("ISO8601DateFormatter().string(from:")
            || src.contains("ISO8601DateFormatter().date(from:")
        return allOurs && hasRewriteableForm
    }

    private func makeProject(_ files: [String: String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FVFusion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, body) in files {
            try body.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return dir
    }

    private func swiftFiles(in dir: URL) throws -> [URL] {
        var out: [URL] = []
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        while let u = e?.nextObject() as? URL {
            if u.pathExtension == "swift" { out.append(u) }
        }
        return out
    }

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
}
