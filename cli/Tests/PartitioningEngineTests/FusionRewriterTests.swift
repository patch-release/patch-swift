// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CodeGenerator
@testable import Compiler

/// FUSION (breakthrough #2) tests — the call-site rewriter that lets a real-source
/// function whose ONE native leaf is bridgeable (UserDefaults/Locale/logging) COMPILE
/// instead of demoting, by rewriting that leaf to a `patch`/`patch_host` host-bridge
/// import and contributing a `FusionCHost` C target carrying the flat-ABI imports.
///
/// These are pure (no WASM toolchain): they assert the rewrite is correct + narrow,
/// the generated bridge package files match the live SDK registrations, and the
/// demote-safety contract (don't rewrite what you don't recognize) holds.
final class FusionRewriterTests: XCTestCase {

    // MARK: - Leaf rewrites

    func testRewritesUserDefaultsStringGet() {
        let src = """
        func pref() -> String {
            return UserDefaults.standard.string(forKey: "currencyCode") ?? "USD"
        }
        """
        let r = FusionRewriter().rewrite(src)
        XCTAssertTrue(r.didRewrite)
        XCTAssertTrue(r.bridgedLeaves.contains("UserDefaults.string(forKey:)"))
        XCTAssertTrue(r.source.contains(#"_patchFusionDefaultsGetString("currencyCode")"#),
                      "key expression must carry through verbatim; got:\n\(r.source)")
        XCTAssertFalse(r.source.contains("UserDefaults.standard.string"),
                       "the native call must be fully replaced")
    }

    func testRewritesUserDefaultsSet() {
        let src = #"UserDefaults.standard.set(code, forKey: "currencyCode")"#
        let r = FusionRewriter().rewrite(src)
        XCTAssertTrue(r.bridgedLeaves.contains("UserDefaults.set(_:forKey:)"))
        XCTAssertTrue(r.source.contains(#"_patchFusionDefaultsSetString(code, "currencyCode")"#),
                      "value + key must carry through in order; got: \(r.source)")
    }

    func testRewritesLocaleIdentifier() {
        let src = "let id = Locale.current.identifier"
        let r = FusionRewriter().rewrite(src)
        XCTAssertTrue(r.bridgedLeaves.contains("Locale.current.identifier"))
        XCTAssertEqual(r.source, "let id = _patchFusionLocaleIdentifier()")
    }

    func testRewritesTimeZoneIdentifier() {
        let src = "let tz = TimeZone.current.identifier"
        let r = FusionRewriter().rewrite(src)
        XCTAssertTrue(r.bridgedLeaves.contains("TimeZone.current.identifier"))
        XCTAssertEqual(r.source, "let tz = _patchFusionTimeZoneIdentifier()")
    }

    func testRewritesSingleArgNSLog() {
        let src = #"NSLog(message)"#
        let r = FusionRewriter().rewrite(src)
        XCTAssertTrue(r.bridgedLeaves.contains("NSLog(_:)"))
        XCTAssertEqual(r.source, "_patchFusionLog(1, message)")
    }

    func testRewritesMultipleLeavesInOneFile() {
        let src = """
        struct Settings {
            func currency() -> String {
                UserDefaults.standard.string(forKey: "cur") ?? Locale.current.identifier
            }
        }
        """
        let r = FusionRewriter().rewrite(src)
        XCTAssertEqual(r.bridgedLeaves, ["UserDefaults.string(forKey:)", "Locale.current.identifier"])
        XCTAssertTrue(r.source.contains("_patchFusionDefaultsGetString"))
        XCTAssertTrue(r.source.contains("_patchFusionLocaleIdentifier()"))
    }

    // MARK: - LEVER #2: Date/Calendar/Formatter builder rewrites

    /// The concrete real-app target: `SettingsScreen.relativeString` — a 3-statement
    /// `RelativeDateTimeFormatter` builder collapses to ONE shim call carrying the two
    /// Dates + the resolved unitsStyle code, and `relativeTo: .now` routes through the
    /// host clock (the `…ToNow` shim).
    func testRewritesRelativeStringBuilderToNow() {
        let src = """
        func relativeString(from date: Date) -> String {
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .abbreviated
            return f.localizedString(for: date, relativeTo: .now)
        }
        """
        let r = FusionRewriter().rewrite(src)
        XCTAssertTrue(r.bridgedLeaves.contains("RelativeDateTimeFormatter.localizedString(for:relativeTo:)"),
                      "the builder block must lower; got:\n\(r.source)")
        XCTAssertFalse(r.source.contains("RelativeDateTimeFormatter"),
                       "no formatter token may remain (else it stays a T2 ICU blocker)")
        XCTAssertTrue(r.source.contains("return _patchFusionRelativeDateStringToNow(date, _patchFusionRelStyle_abbreviated)"),
                      "abbreviated style, .now routes through the host clock, `return` preserved; got:\n\(r.source)")
    }

    /// A `relativeTo:` that is NOT `.now` keeps both Dates and uses the 2-arg shim.
    func testRewritesRelativeStringBuilderExplicitRef() {
        let src = """
        func ago(_ d: Date, _ ref: Date) -> String {
            let fmt = RelativeDateTimeFormatter()
            fmt.unitsStyle = .full
            return fmt.localizedString(for: d, relativeTo: ref)
        }
        """
        let r = FusionRewriter().rewrite(src)
        XCTAssertTrue(r.bridgedLeaves.contains("RelativeDateTimeFormatter.localizedString(for:relativeTo:)"))
        XCTAssertTrue(r.source.contains("return _patchFusionRelativeDateString(d, ref, _patchFusionRelStyle_full)"),
                      "full style, explicit ref → 2-Date shim, `return` preserved; got:\n\(r.source)")
    }

    /// A bare `RelativeDateTimeFormatter()` with NO `.unitsStyle` set (defaults to
    /// `.full`) still collapses (the no-style builder pattern).
    func testRewritesRelativeStringNoStyleSet() {
        let src = """
        func ago(_ d: Date) -> String {
            let f = RelativeDateTimeFormatter()
            return f.localizedString(for: d, relativeTo: .now)
        }
        """
        let r = FusionRewriter().rewrite(src)
        XCTAssertTrue(r.bridgedLeaves.contains("RelativeDateTimeFormatter.localizedString(for:relativeTo:)"))
        XCTAssertTrue(r.source.contains("return _patchFusionRelativeDateStringToNow(d, 0)"),
                      "no unitsStyle → default .full=0, `return` preserved; got:\n\(r.source)")
    }

    func testRewritesCalendarStartOfDay() {
        let src = "let midnight = Calendar.current.startOfDay(for: when)"
        let r = FusionRewriter().rewrite(src)
        XCTAssertTrue(r.bridgedLeaves.contains("Calendar.current.startOfDay(for:)"))
        XCTAssertEqual(r.source, "let midnight = _patchFusionCalendarStartOfDay(when)")
    }

    func testRewritesCalendarSameDay() {
        let src = "if Calendar.current.isDate(a, inSameDayAs: b) { return true }"
        let r = FusionRewriter().rewrite(src)
        XCTAssertTrue(r.bridgedLeaves.contains("Calendar.current.isDate(_:inSameDayAs:)"))
        XCTAssertTrue(r.source.contains("_patchFusionCalendarSameDay(a, b)"),
                      "got: \(r.source)")
    }

    /// The relative-date leaf's generated header declares BOTH its own import AND the
    /// `now_unix_millis` clock import (so the `…ToNow` shim is self-contained), and the
    /// per-declaration dedup emits `now_unix_millis` exactly once even when the
    /// `Date().timeIntervalSince1970` leaf ALSO fires.
    func testRelativeDateHeaderDedupsNowImport() {
        let rw = FusionRewriter()
        let bridges = rw.bridges(forLeaves: [
            "RelativeDateTimeFormatter.localizedString(for:relativeTo:)",
            "Date().timeIntervalSince1970",
        ])
        let h = rw.headerSource(for: bridges)
        XCTAssertTrue(h.contains(#"WASM_IMPORT("patch_host","relative_date_format")"#))
        // `now_unix_millis` must be declared EXACTLY ONCE (declared by both bridges).
        let occurrences = h.components(separatedBy: #"WASM_IMPORT("patch_host","now_unix_millis")"#).count - 1
        XCTAssertEqual(occurrences, 1, "the shared now_unix_millis import must be deduped to one decl")
    }

    /// A CONFIGURED RelativeDateTimeFormatter (an extra property set, a stored/reused
    /// formatter) does NOT match the canonical builder → left verbatim (demote-safe).
    func testDoesNotRewriteConfiguredRelativeFormatter() {
        let src = """
        func ago(_ d: Date) -> String {
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .abbreviated
            f.dateTimeStyle = .named
            return f.localizedString(for: d, relativeTo: .now)
        }
        """
        let r = FusionRewriter().rewrite(src)
        XCTAssertFalse(r.bridgedLeaves.contains("RelativeDateTimeFormatter.localizedString(for:relativeTo:)"),
                       "an extra property set (dateTimeStyle) breaks the canonical builder → not rewritten")
    }

    // MARK: - Demote-safety (don't rewrite what you don't recognize)

    func testDoesNotRewritePureValueLogic() {
        let src = """
        struct Money { let cents: Int
            func formatted() -> String { "\\(cents)" }
        }
        """
        let r = FusionRewriter().rewrite(src)
        XCTAssertFalse(r.didRewrite)
        XCTAssertEqual(r.source, src, "pure value logic must pass through byte-identical")
    }

    func testDoesNotRewriteFileSystemWriteLeaf() {
        // Breakthrough #8 bridges the READ-ONLY FileManager surface only. A WRITE/
        // mutating member (removeItem/createFile/write(toFile:)) has no safe
        // value-bridge → it must NOT be rewritten, so a file-writer still demotes
        // (and the registry keeps it native via the mustStayNative member guard).
        let src = "try FileManager.default.removeItem(atPath: p)"
        let r = FusionRewriter().rewrite(src)
        XCTAssertFalse(r.didRewrite, "a file WRITE/delete must never be rewritten")
        XCTAssertEqual(r.source, src)
    }

    func testDoesNotRewriteFormatStringNSLog() {
        // A printf-style NSLog has a comma → it is NOT the single-string form and must
        // be left native (the format-arg marshalling is out of scope), so it demotes.
        let src = #"NSLog("%@ count=%d", name, n)"#
        let r = FusionRewriter().rewrite(src)
        XCTAssertFalse(r.bridgedLeaves.contains("NSLog(_:)"),
                       "multi-arg NSLog must not be rewritten")
        XCTAssertEqual(r.source, src)
    }

    // MARK: - Bridge package artifacts match the live SDK ABI

    func testHeaderDeclaresFlatImportsForFiredLeaves() {
        let rw = FusionRewriter()
        let bridges = rw.bridges(forLeaves: ["UserDefaults.string(forKey:)", "Locale.current.identifier"])
        let h = rw.headerSource(for: bridges)
        // patch.defaults_get and patch.locale_identifier — the EXACT module+name the SDK
        // registers (UserDefaultsBridge / DateLocaleBridge live under module "patch").
        XCTAssertTrue(h.contains(#"WASM_IMPORT("patch","defaults_get")"#))
        XCTAssertTrue(h.contains("int64_t patch_defaults_get(const uint8_t* key, int32_t keyLen);"))
        XCTAssertTrue(h.contains(#"WASM_IMPORT("patch","locale_identifier")"#))
        // Only the fired leaves are declared (not the whole table).
        XCTAssertFalse(h.contains("defaults_set"))
    }

    func testFilesCarryModuleTokenForSwiftTarget() {
        let rw = FusionRewriter()
        let bridges = rw.bridges(forLeaves: ["UserDefaults.string(forKey:)"])
        let files = rw.files(bridges: bridges, swiftTargetName: "__MODULE__")
        let paths = files.map { $0.relativePath }
        XCTAssertTrue(paths.contains("Sources/FusionCHost/include/fusion_chost.h"))
        XCTAssertTrue(paths.contains("Sources/FusionCHost/shim.c"))
        XCTAssertTrue(paths.contains("Sources/__MODULE__/_patch_fusion_bridge.swift"),
                      "the Swift bridge shim path must carry the __MODULE__ token the "
                      + "compiler substitutes with the real module name")
        // The Swift bridge imports the C target and defines the shim the rewrite calls.
        let swift = files.first { $0.relativePath.hasSuffix("_patch_fusion_bridge.swift") }!.contents
        XCTAssertTrue(swift.contains("import FusionCHost"))
        XCTAssertTrue(swift.contains("func _patchFusionDefaultsGetString"))
        XCTAssertTrue(swift.contains("_patchFusionReadString"), "shared marshalling helper present")
    }

    func testEveryBridgeTargetsAKnownSDKModule() {
        // Guard the patch-vs-patch_host drift: every entry must target one of the two
        // real SDK namespaces.
        for b in FusionRewriter.allBridges {
            XCTAssertTrue(b.cImportModule == "patch" || b.cImportModule == "patch_host",
                          "\(b.id) targets unknown module \(b.cImportModule)")
            XCTAssertFalse(b.cImportName.isEmpty)
        }
    }

    // MARK: - Breakthrough #8 family rewrites

    func testRewritesFileExists() {
        let r = FusionRewriter().rewrite("let ok = FileManager.default.fileExists(atPath: path)")
        XCTAssertTrue(r.bridgedLeaves.contains("FileManager.default.fileExists(atPath:)"))
        XCTAssertEqual(r.source, "let ok = _patchFusionFileExists(path)")
    }

    func testRewritesFileContents() {
        let r = FusionRewriter().rewrite("let d = FileManager.default.contents(atPath: p)")
        XCTAssertTrue(r.bridgedLeaves.contains("FileManager.default.contents(atPath:)"))
        XCTAssertEqual(r.source, "let d = _patchFusionFileContents(p)")
    }

    func testRewritesAttributesSize() {
        let src = "let n = FileManager.default.attributesOfItem(atPath: p)[.size] as? Int"
        let r = FusionRewriter().rewrite(src)
        XCTAssertTrue(r.bridgedLeaves.contains("FileManager.default.attributesOfItem(.size)"))
        XCTAssertEqual(r.source, "let n = Int(_patchFusionFileSize(p))")
    }

    func testRewritesBundleInfoString() {
        let src = #"let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String"#
        let r = FusionRewriter().rewrite(src)
        XCTAssertTrue(r.bridgedLeaves.contains("Bundle.main.object(forInfoDictionaryKey:)"))
        XCTAssertEqual(r.source, #"let v = _patchFusionBundleInfoString("CFBundleShortVersionString")"#)
    }

    func testRewritesBundleResourcePath() {
        let src = #"let p = Bundle.main.path(forResource: "Config", ofType: "json")"#
        let r = FusionRewriter().rewrite(src)
        XCTAssertTrue(r.bridgedLeaves.contains("Bundle.main.path(forResource:ofType:)"))
        XCTAssertEqual(r.source, #"let p = _patchFusionBundleResourcePath("Config", "json")"#)
    }

    func testRewritesProcessEnv() {
        let src = #"let h = ProcessInfo.processInfo.environment["HOME"]"#
        let r = FusionRewriter().rewrite(src)
        XCTAssertTrue(r.bridgedLeaves.contains("ProcessInfo.processInfo.environment[]"))
        XCTAssertEqual(r.source, #"let h = _patchFusionProcessEnv("HOME")"#)
    }

    func testRewritesOSVersion() {
        let r = FusionRewriter().rewrite("let v = ProcessInfo.processInfo.operatingSystemVersion")
        XCTAssertTrue(r.bridgedLeaves.contains("ProcessInfo.processInfo.operatingSystemVersion"))
        XCTAssertEqual(r.source, "let v = _patchFusionOSVersion()")
    }

    func testRewritesDefaultsBool() {
        let r = FusionRewriter().rewrite(#"let b = UserDefaults.standard.bool(forKey: "flag")"#)
        XCTAssertTrue(r.bridgedLeaves.contains("UserDefaults.bool(forKey:)"))
        XCTAssertEqual(r.source, #"let b = _patchFusionDefaultsGetBool("flag")"#)
    }

    func testRewritesDefaultsInteger() {
        let r = FusionRewriter().rewrite(#"let n = UserDefaults.standard.integer(forKey: "count")"#)
        XCTAssertTrue(r.bridgedLeaves.contains("UserDefaults.integer(forKey:)"))
        XCTAssertEqual(r.source, #"let n = _patchFusionDefaultsGetInt("count")"#)
    }

    /// A fused function — pure value logic over TWO bridged family leaves (the exact
    /// class of demoted function the family unlocks) — rewrites both, no native left.
    func testRewritesFusedTwoLeafFunction() {
        let src = """
        func gate() -> Int {
            let launches = UserDefaults.standard.integer(forKey: "launchCount")
            let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
            return launches * 10 + major
        }
        """
        let r = FusionRewriter().rewrite(src)
        XCTAssertTrue(r.bridgedLeaves.contains("UserDefaults.integer(forKey:)"))
        XCTAssertTrue(r.bridgedLeaves.contains("ProcessInfo.processInfo.operatingSystemVersion"))
        XCTAssertTrue(r.source.contains("_patchFusionDefaultsGetInt(\"launchCount\")"))
        XCTAssertTrue(r.source.contains("_patchFusionOSVersion().majorVersion"))
        XCTAssertFalse(r.source.contains("UserDefaults.standard"))
        XCTAssertFalse(r.source.contains("ProcessInfo.processInfo"))
    }

    // MARK: - Import parity (engine half of the audit spot-check)

    /// The flat `patch_host` import names the family emits. The SDK side
    /// (`HostBridgeFamilyTests.engineEmittedPatchHostFamilyImports` /
    /// `testEveryEmittedFamilyImportIsServedByDefaults`) asserts `registerDefaults()`
    /// SERVES every one of these — i.e. emitted ⊆ served (the audit spot-check).
    static let expectedPatchHostFamilyImports: Set<String> = [
        "file_exists", "file_read", "file_size",
        "bundle_info_string", "bundle_resource_path",
        "process_env", "os_version",
        "defaults_get_bool", "defaults_get_int",
        // Typed UserDefaults get/set (the settings-toggle workhorse): the Double get
        // + the Bool/Int/Double setters. The String get/set live under module "patch"
        // (UserDefaultsBridge), so they are NOT in this patch_host set.
        "defaults_get_double", "defaults_set_bool", "defaults_set_int", "defaults_set_double",
        // Foundation VALUE bridges (date math / ISO8601). `now_unix_millis` is the
        // shell's real clock (Date().timeIntervalSince*); iso8601_format/_parse are the
        // fixed-format ISO8601 string<->date pair. All served by FoundationBridge.
        "now_unix_millis", "iso8601_format", "iso8601_parse",
        // LEVER #2: Date/Calendar/Formatter (locale/ICU on the shell). `number_format`
        // already existed in the SDK; the builder-form rewrites now target it +
        // relative_date_format + calendar_date_op. All served by FoundationBridge.
        "relative_date_format", "number_format", "calendar_date_op",
        // LEVER: Regex (the shell's real ICU NSRegularExpression). The
        // .regularExpression String shapes + bare NSRegularExpression(pattern:) member
        // forms rewrite to these. All served by FoundationBridge. (regex_capture is a
        // registered bridge — emitted in the header/shim when requested — even though no
        // textual pattern auto-fires it yet; capture extraction is multi-statement.)
        "regex_test", "regex_capture", "regex_count", "regex_replace",
        // Breakthrough #6 networking (async) — same patch_host namespace. Only
        // http_get is EMITTED in v1 (data(for:)/http_request deferred — URLRequest
        // is absent in the WASM-SDK guest Foundation).
        "http_get",
    ]

    func testFamilyEmitsExactlyTheExpectedPatchHostImports() {
        let emitted = Set(FusionRewriter.allBridges
            .filter { $0.cImportModule == "patch_host" }
            .map { $0.cImportName })
        XCTAssertEqual(emitted, Self.expectedPatchHostFamilyImports,
                       "engine-emitted patch_host family imports must match the SDK-served set")
    }

    /// The C header declares each emitted import with the EXACT module+name the SDK
    /// registers, so the generated flat-ABI header resolves against the SDK host.
    func testFamilyHeaderDeclaresFlatPatchHostImports() {
        let rw = FusionRewriter()
        let bridges = rw.bridges(forLeaves: [
            "FileManager.default.fileExists(atPath:)",
            "ProcessInfo.processInfo.operatingSystemVersion",
            "UserDefaults.integer(forKey:)",
        ])
        let h = rw.headerSource(for: bridges)
        XCTAssertTrue(h.contains(#"WASM_IMPORT("patch_host","file_exists")"#))
        XCTAssertTrue(h.contains("int32_t patch_file_exists(const uint8_t* path, int32_t pathLen);"))
        XCTAssertTrue(h.contains(#"WASM_IMPORT("patch_host","os_version")"#))
        XCTAssertTrue(h.contains(#"WASM_IMPORT("patch_host","defaults_get_int")"#))
    }

    // MARK: - Demote-safety for the new family

    func testDoesNotRewriteNonStringBundleObject() {
        // object(forInfoDictionaryKey:) WITHOUT the `as? String` tail returns Any?
        // (could be an array/dict) — not the bridged String shape, so it is left
        // native and demotes.
        let src = #"let arr = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes")"#
        let r = FusionRewriter().rewrite(src)
        XCTAssertFalse(r.bridgedLeaves.contains("Bundle.main.object(forInfoDictionaryKey:)"))
        XCTAssertEqual(r.source, src)
    }

    func testDoesNotRewriteBridgeCallInsideStringLiteral() {
        // A bridge call FORM appearing inside a string literal value must NOT be
        // rewritten (the code-mask guard) — would corrupt the literal.
        let src = #"let doc = "call FileManager.default.fileExists(atPath: x) to check""#
        let r = FusionRewriter().rewrite(src)
        XCTAssertFalse(r.didRewrite)
        XCTAssertEqual(r.source, src)
    }

    // MARK: - BuildPipeline integration (no toolchain)

    /// Fusion off → closure passes through unchanged and contributes no bridge files
    /// (the manifest stays single-target; the non-fusion path is byte-identical).
    func testApplyFusionRewriteDisabledIsNoOp() throws {
        let pipeline = makePipeline()
        let dir = try makeTempDir()
        let f = dir.appendingPathComponent("S.swift")
        try #"let x = UserDefaults.standard.string(forKey: "k")"#.write(to: f, atomically: true, encoding: .utf8)
        let (closure, files) = try pipeline.applyFusionRewrite(
            [f], enabled: false, moduleName: "App", rsBuildDir: dir, label: "t", log: { _ in })
        XCTAssertEqual(closure, [f])
        XCTAssertTrue(files.isEmpty)
    }

    /// Fusion on + a bridgeable leaf → the closure file is replaced by a rewritten copy
    /// and the FusionCHost bridge files are produced.
    func testApplyFusionRewriteEnabledRewritesAndEmitsFiles() throws {
        let pipeline = makePipeline()
        let dir = try makeTempDir()
        let f = dir.appendingPathComponent("S.swift")
        try #"let x = UserDefaults.standard.string(forKey: "k")"#.write(to: f, atomically: true, encoding: .utf8)
        let (closure, files) = try pipeline.applyFusionRewrite(
            [f], enabled: true, moduleName: "App", rsBuildDir: dir, label: "coarse", log: { _ in })
        XCTAssertNotEqual(closure, [f], "the original file must be replaced by a rewritten copy")
        let rewritten = try String(contentsOf: closure[0], encoding: .utf8)
        XCTAssertTrue(rewritten.contains("_patchFusionDefaultsGetString"))
        XCTAssertFalse(files.isEmpty, "bridge files must be emitted")
        XCTAssertTrue(files.contains { $0.relativePath == "Sources/FusionCHost/shim.c" })
    }

    /// Fusion on + an openURL + NotificationCenter closure → both call sites lower and
    /// the patch-namespace bridge files are produced (the new business-logic leaves
    /// flow through the whole pipeline, not just the rewriter in isolation).
    func testApplyFusionRewriteLowersOpenURLAndNotify() throws {
        let pipeline = makePipeline()
        let dir = try makeTempDir()
        let f = dir.appendingPathComponent("Action.swift")
        try """
        func act(url: URL) {
            UIApplication.shared.open(url)
            NotificationCenter.default.post(name: .didOpen, object: nil)
        }
        """.write(to: f, atomically: true, encoding: .utf8)
        let (closure, files) = try pipeline.applyFusionRewrite(
            [f], enabled: true, moduleName: "App", rsBuildDir: dir, label: "coarse", log: { _ in })
        XCTAssertNotEqual(closure, [f], "the file must be replaced by a rewritten copy")
        let rewritten = try String(contentsOf: closure[0], encoding: .utf8)
        XCTAssertTrue(rewritten.contains("_patchFusionOpenURL(url)"))
        XCTAssertTrue(rewritten.contains("_patchFusionNotifyPost(.didOpen)"))
        XCTAssertFalse(rewritten.contains("UIApplication.shared.open"))
        XCTAssertFalse(rewritten.contains("NotificationCenter.default.post"))
        XCTAssertTrue(files.contains { $0.relativePath == "Sources/FusionCHost/shim.c" })
    }

    /// The fusion-eligibility gate must list the new business-logic symbols, in
    /// lock-step with the rewriter (a function blocked only by these is offered to
    /// the real-source compile, which lowers the recognized call sites).
    func testFusionRewriteableSymbolsCoverNewLeaves() {
        let s = BuildPipeline.fusionRewriteableSymbols
        XCTAssertTrue(s.contains("UserDefaults"))
        XCTAssertTrue(s.contains("NotificationCenter"))
        XCTAssertTrue(s.contains("UIApplication"))
    }

    /// Fusion on but NO bridgeable leaf → no rewrite, no bridge files (manifest stays
    /// single-target → canaries unaffected even with fusion enabled).
    func testApplyFusionRewriteEnabledButNoLeafIsNoOp() throws {
        let pipeline = makePipeline()
        let dir = try makeTempDir()
        let f = dir.appendingPathComponent("Pure.swift")
        try "struct V { let n: Int; func f() -> Int { n * 2 } }".write(to: f, atomically: true, encoding: .utf8)
        let (closure, files) = try pipeline.applyFusionRewrite(
            [f], enabled: true, moduleName: "App", rsBuildDir: dir, label: "coarse", log: { _ in })
        XCTAssertEqual(closure, [f])
        XCTAssertTrue(files.isEmpty)
    }

    // MARK: - Typed UserDefaults set (literal value) + double get

    func testRewritesDefaultsSetBool() {
        let r = FusionRewriter().rewrite(#"UserDefaults.standard.set(true, forKey: "darkMode")"#)
        XCTAssertTrue(r.bridgedLeaves.contains("UserDefaults.set(Bool:forKey:)"))
        XCTAssertEqual(r.source, #"_patchFusionDefaultsSetBool(true, "darkMode")"#)
    }

    func testRewritesDefaultsSetBoolFalse() {
        let r = FusionRewriter().rewrite(#"UserDefaults.standard.set(false, forKey: key)"#)
        XCTAssertTrue(r.bridgedLeaves.contains("UserDefaults.set(Bool:forKey:)"))
        XCTAssertEqual(r.source, "_patchFusionDefaultsSetBool(false, key)")
    }

    func testRewritesDefaultsSetInt() {
        let r = FusionRewriter().rewrite(#"UserDefaults.standard.set(42, forKey: "count")"#)
        XCTAssertTrue(r.bridgedLeaves.contains("UserDefaults.set(Int:forKey:)"))
        XCTAssertEqual(r.source, #"_patchFusionDefaultsSetInt(42, "count")"#)
    }

    func testRewritesDefaultsSetNegativeInt() {
        let r = FusionRewriter().rewrite(#"UserDefaults.standard.set(-7, forKey: "offset")"#)
        XCTAssertTrue(r.bridgedLeaves.contains("UserDefaults.set(Int:forKey:)"))
        XCTAssertEqual(r.source, #"_patchFusionDefaultsSetInt(-7, "offset")"#)
    }

    func testRewritesDefaultsSetDouble() {
        let r = FusionRewriter().rewrite(#"UserDefaults.standard.set(0.75, forKey: "volume")"#)
        XCTAssertTrue(r.bridgedLeaves.contains("UserDefaults.set(Double:forKey:)"))
        XCTAssertEqual(r.source, #"_patchFusionDefaultsSetDouble(0.75, "volume")"#)
    }

    /// A NON-literal value is ambiguous (could be any type) → it must route to the
    /// String shim (which compiles only if it really is a String, else demotes). The
    /// typed patterns must NOT capture it (the negative-lookahead on the String
    /// pattern + the literal-anchored typed patterns guarantee this).
    func testNonLiteralSetRoutesToStringShim() {
        let r = FusionRewriter().rewrite(#"UserDefaults.standard.set(userName, forKey: "user")"#)
        XCTAssertTrue(r.bridgedLeaves.contains("UserDefaults.set(_:forKey:)"))
        XCTAssertFalse(r.bridgedLeaves.contains("UserDefaults.set(Bool:forKey:)"))
        XCTAssertFalse(r.bridgedLeaves.contains("UserDefaults.set(Int:forKey:)"))
        XCTAssertEqual(r.source, #"_patchFusionDefaultsSetString(userName, "user")"#)
    }

    func testRewritesDefaultsDoubleGet() {
        let r = FusionRewriter().rewrite(#"let v = UserDefaults.standard.double(forKey: "vol")"#)
        XCTAssertTrue(r.bridgedLeaves.contains("UserDefaults.double(forKey:)"))
        XCTAssertEqual(r.source, #"let v = _patchFusionDefaultsGetDouble("vol")"#)
    }

    /// A representative settings-toggle action: read a Double, mutate, write a Bool +
    /// Double back. ALL leaves lower; no native UserDefaults call remains — the whole
    /// closure runs in WASM.
    func testRewritesFusedSettingsToggle() {
        let src = """
        func toggle() {
            let vol = UserDefaults.standard.double(forKey: "volume")
            UserDefaults.standard.set(vol > 0.5, forKey: "loud")
            UserDefaults.standard.set(0.25, forKey: "volume")
            UserDefaults.standard.set(true, forKey: "didToggle")
        }
        """
        let r = FusionRewriter().rewrite(src)
        XCTAssertTrue(r.bridgedLeaves.contains("UserDefaults.double(forKey:)"))
        XCTAssertTrue(r.bridgedLeaves.contains("UserDefaults.set(Bool:forKey:)"))
        XCTAssertTrue(r.bridgedLeaves.contains("UserDefaults.set(Double:forKey:)"))
        XCTAssertFalse(r.source.contains("UserDefaults.standard"),
                       "every UserDefaults call site must be lowered; got:\n\(r.source)")
    }

    // MARK: - URL open (UIApplication.shared.open) rewrites

    func testRewritesUIApplicationOpen() {
        let r = FusionRewriter().rewrite("UIApplication.shared.open(url)")
        XCTAssertTrue(r.bridgedLeaves.contains("UIApplication.shared.open(_:)"))
        XCTAssertEqual(r.source, "_patchFusionOpenURL(url)")
    }

    /// The `open(_:options:completionHandler:)` overload has extra args (a comma in
    /// the call) → NOT the single-URL form, so it must stay native + demote (the
    /// completion handler can't be bridged).
    func testDoesNotRewriteUIApplicationOpenWithCompletion() {
        let src = "UIApplication.shared.open(url, options: [:], completionHandler: nil)"
        let r = FusionRewriter().rewrite(src)
        XCTAssertFalse(r.didRewrite, "the options/completion overload must not be rewritten")
        XCTAssertEqual(r.source, src)
    }

    func testDoesNotRewriteOpenInsideStringLiteral() {
        let src = #"let doc = "tap to UIApplication.shared.open(url)""#
        let r = FusionRewriter().rewrite(src)
        XCTAssertFalse(r.didRewrite)
        XCTAssertEqual(r.source, src)
    }

    /// The openURL shim is `@discardableResult` so a bare fire-and-forget statement
    /// compiles, and accepts `_PatchURLLike` (URL or String).
    func testOpenURLShimIsDiscardableAndURLLike() {
        let rw = FusionRewriter()
        let bridges = rw.bridges(forLeaves: ["UIApplication.shared.open(_:)"])
        let s = rw.swiftBridgeSource(for: bridges, cTargetName: "FusionCHost")
        XCTAssertTrue(s.contains("@discardableResult"))
        XCTAssertTrue(s.contains("func _patchFusionOpenURL(_ url: _PatchURLLike)"))
        // openURL is a URL-consuming leaf → the shared _PatchURLLike helper + Foundation
        // must be emitted even though NO async/networking bridge fired.
        XCTAssertTrue(s.contains("protocol _PatchURLLike"), "URL helper must be emitted for open_url")
        XCTAssertTrue(s.contains("import Foundation"), "open_url shim uses URL → needs Foundation")
        // ...but NOT the async networking machinery.
        XCTAssertFalse(s.contains("patch_resolve_http"))
        XCTAssertFalse(s.contains("withCheckedContinuation"))
    }

    func testOpenURLHeaderDeclaresFlatPatchImport() {
        let rw = FusionRewriter()
        let h = rw.headerSource(for: rw.bridges(forLeaves: ["UIApplication.shared.open(_:)"]))
        XCTAssertTrue(h.contains(#"WASM_IMPORT("patch","open_url")"#))
        XCTAssertTrue(h.contains("int32_t patch_open_url(const uint8_t* url, int32_t urlLen);"))
    }

    // MARK: - NotificationCenter.post rewrites

    func testRewritesNotificationPost() {
        let r = FusionRewriter().rewrite("NotificationCenter.default.post(name: .didUpdate, object: nil)")
        XCTAssertTrue(r.bridgedLeaves.contains("NotificationCenter.default.post(name:object:nil)"))
        XCTAssertEqual(r.source, "_patchFusionNotifyPost(.didUpdate)")
    }

    /// A NON-nil object: has no value-marshalling path → must NOT be rewritten.
    func testDoesNotRewriteNotificationPostWithObject() {
        let src = "NotificationCenter.default.post(name: .didUpdate, object: self)"
        let r = FusionRewriter().rewrite(src)
        XCTAssertFalse(r.didRewrite, "a non-nil object: must not be bridged")
        XCTAssertEqual(r.source, src)
    }

    /// `addObserver` must NEVER be rewritten — a guest closure observer would outlive
    /// the WASM instance (use-after-free). It stays native.
    func testDoesNotRewriteAddObserver() {
        let src = "NotificationCenter.default.addObserver(self, selector: #selector(h), name: .x, object: nil)"
        let r = FusionRewriter().rewrite(src)
        XCTAssertFalse(r.didRewrite, "addObserver must stay native (observer outlives the WASM instance)")
        XCTAssertEqual(r.source, src)
    }

    func testNotifyPostShimReadsRawValueAndNeedsFoundation() {
        let rw = FusionRewriter()
        let s = rw.swiftBridgeSource(for: rw.bridges(forLeaves: ["NotificationCenter.default.post(name:object:nil)"]),
                                     cTargetName: "FusionCHost")
        XCTAssertTrue(s.contains("func _patchFusionNotifyPost(_ name: Notification.Name)"))
        XCTAssertTrue(s.contains("name.rawValue"))
        XCTAssertTrue(s.contains("import Foundation"), "Notification.Name is a Foundation value type")
        // notify_post does NOT use a URL → the _PatchURLLike helper must NOT be emitted.
        XCTAssertFalse(s.contains("protocol _PatchURLLike"))
    }

    func testNotifyPostHeaderDeclaresFlatPatchImport() {
        let rw = FusionRewriter()
        let h = rw.headerSource(for: rw.bridges(forLeaves: ["NotificationCenter.default.post(name:object:nil)"]))
        XCTAssertTrue(h.contains(#"WASM_IMPORT("patch","notify_post")"#))
        XCTAssertTrue(h.contains("void patch_notify_post(const uint8_t* name, int32_t nameLen);"))
    }

    // MARK: - Typed-set bridge package artifacts

    func testTypedSetHeaderDeclaresFlatPatchHostImports() {
        let rw = FusionRewriter()
        let bridges = rw.bridges(forLeaves: [
            "UserDefaults.set(Bool:forKey:)", "UserDefaults.set(Int:forKey:)",
            "UserDefaults.set(Double:forKey:)", "UserDefaults.double(forKey:)",
        ])
        let h = rw.headerSource(for: bridges)
        XCTAssertTrue(h.contains(#"WASM_IMPORT("patch_host","defaults_set_bool")"#))
        XCTAssertTrue(h.contains("void patch_defaults_set_bool(const uint8_t* key, int32_t keyLen, int32_t value);"))
        XCTAssertTrue(h.contains(#"WASM_IMPORT("patch_host","defaults_set_int")"#))
        XCTAssertTrue(h.contains(#"WASM_IMPORT("patch_host","defaults_set_double")"#))
        XCTAssertTrue(h.contains(#"WASM_IMPORT("patch_host","defaults_get_double")"#))
    }

    // MARK: - Breakthrough #6 networking (async) rewrites

    func testRewritesURLSessionDataFrom() {
        // The canonical `await URLSession.shared.data(from: url)` leaf. The developer's
        // `try await` is left in place; only the call form is replaced by the async shim.
        let src = "let (data, response) = try await URLSession.shared.data(from: url)"
        let r = FusionRewriter().rewrite(src)
        XCTAssertTrue(r.bridgedLeaves.contains("URLSession.data(from:)"))
        XCTAssertEqual(r.source, "let (data, response) = try await _patchFusionURLSessionDataFrom(url)")
        XCTAssertFalse(r.source.contains("URLSession.shared.data"))
    }

    /// `data(for: URLRequest)` is DEFERRED from v1 (URLRequest is absent in the
    /// WASM-SDK guest Foundation) → it must NOT be rewritten; it stays native + demotes.
    func testDoesNotRewriteURLSessionDataFor() {
        let src = "let (data, _) = try await URLSession.shared.data(for: request)"
        let r = FusionRewriter().rewrite(src)
        XCTAssertFalse(r.didRewrite, "data(for:) is deferred (URLRequest absent in WASM)")
        XCTAssertEqual(r.source, src)
    }

    func testNetworkingBridgeIsAsyncAndUnderPatchHost() {
        let b = FusionRewriter.allBridges.first { $0.id == "URLSession.data(from:)" }
        XCTAssertNotNil(b, "URLSession.data(from:) must be registered")
        XCTAssertTrue(b?.isAsync == true, "the networking bridge is async")
        XCTAssertEqual(b?.cImportModule, "patch_host")
        // data(for:) must NOT be a registered bridge (deferred).
        XCTAssertNil(FusionRewriter.allBridges.first { $0.id == "URLSession.data(for:)" })
    }

    /// An async bridge fired → the Swift bridge source imports Foundation, emits the
    /// continuation registry + the `patch_resolve_http` export the host calls back on.
    func testAsyncBridgeSourceEmitsResolveExportAndFoundation() {
        let rw = FusionRewriter()
        let bridges = rw.bridges(forLeaves: ["URLSession.data(from:)"])
        let s = rw.swiftBridgeSource(for: bridges, cTargetName: "FusionCHost")
        XCTAssertTrue(s.contains("import Foundation"), "async shim needs Foundation value types")
        XCTAssertTrue(s.contains(#"@_cdecl("patch_resolve_http")"#),
                      "the host-resume export must be emitted")
        XCTAssertTrue(s.contains("withCheckedContinuation"), "the suspend point must be present")
        XCTAssertTrue(s.contains("_patchFusionURLSessionDataFrom"))
    }

    /// A SYNC-only fusion (no networking) must NOT pull in the async helpers / Foundation
    /// — the #8 family stays exactly as before (no regression in the emitted bridge file).
    func testSyncOnlyBridgeSourceHasNoAsyncHelpers() {
        let rw = FusionRewriter()
        let bridges = rw.bridges(forLeaves: ["UserDefaults.string(forKey:)"])
        let s = rw.swiftBridgeSource(for: bridges, cTargetName: "FusionCHost")
        XCTAssertFalse(s.contains("patch_resolve_http"))
        XCTAssertFalse(s.contains("import Foundation"))
    }

    /// The async header declares the flat http imports with the exact module+name the
    /// SDK serves (parity with `PatchHTTPBridge`).
    func testNetworkingHeaderDeclaresFlatHTTPGetImport() {
        let rw = FusionRewriter()
        let bridges = rw.bridges(forLeaves: ["URLSession.data(from:)"])
        let h = rw.headerSource(for: bridges)
        XCTAssertTrue(h.contains(#"WASM_IMPORT("patch_host","http_get")"#))
        XCTAssertTrue(h.contains("void patch_http_get(const uint8_t* url, int32_t urlLen, int32_t token);"))
    }

    // MARK: - #6 demote-safety (don't over-claim the honest limits)

    func testDoesNotRewriteWebSocketTask() {
        // websocket is out of #6 v1 — must NOT be rewritten (stays native → demotes).
        let src = "let task = URLSession.shared.webSocketTask(with: url)"
        let r = FusionRewriter().rewrite(src)
        XCTAssertFalse(r.didRewrite)
        XCTAssertEqual(r.source, src)
    }

    func testDoesNotRewriteBytesStream() {
        // AsyncBytes streaming is out of #6 v1.
        let src = "let (bytes, _) = try await URLSession.shared.bytes(from: url)"
        let r = FusionRewriter().rewrite(src)
        XCTAssertFalse(r.bridgedLeaves.contains("URLSession.data(from:)"))
        XCTAssertFalse(r.bridgedLeaves.contains("URLSession.data(for:)"))
    }

    func testDoesNotRewriteUploadTask() {
        let src = "let task = URLSession.shared.uploadTask(with: request, from: data)"
        let r = FusionRewriter().rewrite(src)
        XCTAssertFalse(r.didRewrite)
    }

    func testDoesNotRewriteDataFromInsideStringLiteral() {
        // A call form inside a string literal must not be rewritten (code-mask guard).
        let src = #"let doc = "use URLSession.shared.data(from: url) to fetch""#
        let r = FusionRewriter().rewrite(src)
        XCTAssertFalse(r.didRewrite)
        XCTAssertEqual(r.source, src)
    }

    // MARK: - Foundation VALUE bridges (date math / ISO8601)

    func testRewritesDateNowUnixSeconds() {
        let r = FusionRewriter().rewrite("let t = Date().timeIntervalSince1970")
        XCTAssertTrue(r.bridgedLeaves.contains("Date().timeIntervalSince1970"))
        XCTAssertEqual(r.source, "let t = _patchFusionNowUnixSeconds()")
        XCTAssertFalse(r.source.contains("Date()"))
    }

    func testRewritesDateIntervalSinceNow() {
        let r = FusionRewriter().rewrite("let d = Date().timeIntervalSinceNow")
        XCTAssertTrue(r.bridgedLeaves.contains("Date().timeIntervalSinceNow"))
        XCTAssertEqual(r.source, "let d = _patchFusionNowIntervalSinceNow()")
    }

    func testRewritesISO8601StringFrom() {
        let r = FusionRewriter().rewrite("let s = ISO8601DateFormatter().string(from: date)")
        XCTAssertTrue(r.bridgedLeaves.contains("ISO8601DateFormatter().string(from:)"))
        XCTAssertEqual(r.source, "let s = _patchFusionISO8601String(date)")
        XCTAssertFalse(r.source.contains("ISO8601DateFormatter"))
    }

    func testRewritesISO8601DateFrom() {
        let r = FusionRewriter().rewrite(#"let d = ISO8601DateFormatter().date(from: raw)"#)
        XCTAssertTrue(r.bridgedLeaves.contains("ISO8601DateFormatter().date(from:)"))
        XCTAssertEqual(r.source, "let d = _patchFusionISO8601Date(raw)")
    }

    /// A CONFIGURED ISO8601 formatter (`f.formatOptions = …`) is a different format —
    /// the bare-`ISO8601DateFormatter()` pattern must NOT match a `let f = …` builder,
    /// so it stays native and demotes (no wrong format shipped).
    func testDoesNotRewriteConfiguredISO8601Builder() {
        let src = """
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        let s = f.string(from: date)
        """
        let r = FusionRewriter().rewrite(src)
        XCTAssertFalse(r.bridgedLeaves.contains("ISO8601DateFormatter().string(from:)"),
                       "a configured ISO8601 builder must not be rewritten")
        XCTAssertEqual(r.source, src)
    }

    /// A multi-statement `DateFormatter` builder (the locale/timezone-sensitive form)
    /// is deliberately NOT bridged — there is no single deterministic call form, so it
    /// stays native (T2) and is never mis-formatted. This pins the honest boundary.
    func testDoesNotRewriteDateFormatterBuilder() {
        let src = """
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
        """
        let r = FusionRewriter().rewrite(src)
        XCTAssertFalse(r.didRewrite, "the DateFormatter builder form must stay native")
        XCTAssertEqual(r.source, src)
    }

    func testDateValueBridgeShimsAreScalarT0() {
        // The now-seconds + sinceNow shims are PURE scalar (Double) → must NOT pull
        // Foundation (they stay T0). The ISO8601 shims DO use Date → need Foundation.
        let rw = FusionRewriter()
        let scalar = rw.swiftBridgeSource(
            for: rw.bridges(forLeaves: ["Date().timeIntervalSince1970", "Date().timeIntervalSinceNow"]),
            cTargetName: "FusionCHost")
        XCTAssertTrue(scalar.contains("func _patchFusionNowUnixSeconds"))
        XCTAssertFalse(scalar.contains("import Foundation"),
                       "the Date().timeIntervalSince* shims are pure Double → T0, no Foundation")

        let iso = rw.swiftBridgeSource(
            for: rw.bridges(forLeaves: ["ISO8601DateFormatter().string(from:)"]),
            cTargetName: "FusionCHost")
        XCTAssertTrue(iso.contains("func _patchFusionISO8601String"))
        XCTAssertTrue(iso.contains("import Foundation"), "ISO8601 shim uses Date → needs Foundation")
    }

    func testDateValueBridgeHeaderDeclaresFlatPatchHostImports() {
        let rw = FusionRewriter()
        let h = rw.headerSource(for: rw.bridges(forLeaves: [
            "Date().timeIntervalSince1970", "ISO8601DateFormatter().string(from:)",
            "ISO8601DateFormatter().date(from:)",
        ]))
        XCTAssertTrue(h.contains(#"WASM_IMPORT("patch_host","now_unix_millis")"#))
        XCTAssertTrue(h.contains(#"WASM_IMPORT("patch_host","iso8601_format")"#))
        XCTAssertTrue(h.contains("int64_t patch_iso8601_format(int64_t unixMillis);"))
        XCTAssertTrue(h.contains(#"WASM_IMPORT("patch_host","iso8601_parse")"#))
        XCTAssertTrue(h.contains("int64_t patch_iso8601_parse(const uint8_t* str, int32_t strLen);"))
    }

    /// A representative fused function: read the current time + emit an ISO8601 stamp.
    /// Both leaves lower; no `Date()`/`ISO8601DateFormatter` token remains.
    func testRewritesFusedDateStampFunction() {
        let src = """
        func stamp(_ d: Date) -> (Double, String) {
            let now = Date().timeIntervalSince1970
            let iso = ISO8601DateFormatter().string(from: d)
            return (now, iso)
        }
        """
        let r = FusionRewriter().rewrite(src)
        XCTAssertTrue(r.bridgedLeaves.contains("Date().timeIntervalSince1970"))
        XCTAssertTrue(r.bridgedLeaves.contains("ISO8601DateFormatter().string(from:)"))
        XCTAssertFalse(r.source.contains("Date().timeIntervalSince1970"))
        XCTAssertFalse(r.source.contains("ISO8601DateFormatter"))
    }

    func testDoesNotRewriteDateBridgeInsideStringLiteral() {
        let src = #"let doc = "use Date().timeIntervalSince1970 for the epoch""#
        let r = FusionRewriter().rewrite(src)
        XCTAssertFalse(r.didRewrite)
        XCTAssertEqual(r.source, src)
    }

    /// A `Date()` token that is the SUFFIX of another identifier (`effectiveDate()`,
    /// `dueDate()`) or a member access (`obj.Date()`) must NOT be rewritten — the
    /// lead-guard anchors the match to a genuine bare `Date()`. (Without the guard the
    /// `effective`/`obj.` prefix would be left dangling — a correctness bug.)
    func testDoesNotRewriteDateAsIdentifierSuffix() {
        for src in [
            "let t = effectiveDate().timeIntervalSince1970",
            "let t = dueDate().timeIntervalSince1970",
            "let t = obj.Date().timeIntervalSince1970",
        ] {
            let r = FusionRewriter().rewrite(src)
            XCTAssertFalse(r.didRewrite, "must not rewrite a non-bare Date() in: \(src)")
            XCTAssertEqual(r.source, src)
        }
    }

    func testDoesNotRewriteISO8601AsIdentifierSuffix() {
        let src = "let s = MyISO8601DateFormatter().string(from: d)"
        let r = FusionRewriter().rewrite(src)
        XCTAssertFalse(r.didRewrite, "a custom *ISO8601DateFormatter must not be rewritten")
        XCTAssertEqual(r.source, src)
    }

    /// Both `Date()` clock leaves bind the SAME host import (`now_unix_millis`); when
    /// both fire the header must declare it exactly ONCE (dedup by module+name), not
    /// emit a duplicate C declaration.
    func testSharedHostImportDeclaredOnce() {
        let rw = FusionRewriter()
        let bridges = rw.bridges(forLeaves: [
            "Date().timeIntervalSince1970", "Date().timeIntervalSinceNow",
        ])
        let h = rw.headerSource(for: bridges)
        let occurrences = h.components(separatedBy: "int64_t patch_now_unix_millis(void);").count - 1
        XCTAssertEqual(occurrences, 1,
                       "a host import shared by two leaves must be declared exactly once")
        // Both shims are still emitted (distinct functions over the one import).
        let swift = rw.swiftBridgeSource(for: bridges, cTargetName: "FusionCHost")
        XCTAssertTrue(swift.contains("_patchFusionNowUnixSeconds"))
        XCTAssertTrue(swift.contains("_patchFusionNowIntervalSinceNow"))
    }

    // MARK: - LEVER: Regex (the shell's real ICU NSRegularExpression)

    /// `str.range(of: pat, options: .regularExpression) != nil` — the dominant
    /// validation TEST form — collapses to the Bool `_patchFusionRegexTest` shim.
    func testRewritesRangeRegexTestNotNil() {
        let src = #"if email.range(of: "^[^@]+@[^@]+$", options: .regularExpression) != nil { return true }"#
        let r = FusionRewriter().rewrite(src)
        XCTAssertTrue(r.bridgedLeaves.contains("String.range(of:options:.regularExpression)"))
        XCTAssertTrue(r.source.contains(#"_patchFusionRegexTest(email, "^[^@]+@[^@]+$")"#),
                      "receiver + pattern carry through; got:\n\(r.source)")
        XCTAssertFalse(r.source.contains(".regularExpression"), "no regex-option token may remain")
    }

    /// The `== nil` (no-match) form maps to the NEGATED shim so the Bool sense is kept.
    func testRewritesRangeRegexTestEqualNil() {
        let src = #"let invalid = phone.range(of: pattern, options: .regularExpression) == nil"#
        let r = FusionRewriter().rewrite(src)
        XCTAssertTrue(r.bridgedLeaves.contains("String.range(of:options:.regularExpression)"))
        XCTAssertEqual(r.source, "let invalid = !_patchFusionRegexTest(phone, pattern)")
    }

    /// `str.replacingOccurrences(of: pat, with: tmpl, options: .regularExpression)` →
    /// the ICU template `_patchFusionRegexReplace` shim (over the whole string).
    func testRewritesReplacingOccurrencesRegex() {
        let src = #"let clean = raw.replacingOccurrences(of: "[0-9]+", with: "X", options: .regularExpression)"#
        let r = FusionRewriter().rewrite(src)
        XCTAssertTrue(r.bridgedLeaves.contains("String.replacingOccurrences(of:with:.regularExpression)"))
        XCTAssertEqual(r.source, #"let clean = _patchFusionRegexReplace(raw, "[0-9]+", "X")"#)
    }

    /// A LITERAL `replacingOccurrences(of:with:)` (no `.regularExpression` option) is a
    /// different operation → must NOT be rewritten (stays native, demote-safe).
    func testDoesNotRewriteLiteralReplacingOccurrences() {
        let src = #"let s = raw.replacingOccurrences(of: "a", with: "b")"#
        let r = FusionRewriter().rewrite(src)
        XCTAssertFalse(r.didRewrite, "a literal replacingOccurrences must stay native")
        XCTAssertEqual(r.source, src)
    }

    /// A plain `range(of:)` substring search (no `.regularExpression` option) is NOT a
    /// regex op → must NOT be rewritten.
    func testDoesNotRewritePlainRangeOf() {
        let src = #"if name.range(of: "foo") != nil { return }"#
        let r = FusionRewriter().rewrite(src)
        XCTAssertFalse(r.didRewrite, "a plain substring range(of:) must stay native")
        XCTAssertEqual(r.source, src)
    }

    /// The bare single-use `try! NSRegularExpression(pattern:).numberOfMatches(in:range:)`
    /// form collapses to `_patchFusionRegexCount`, dropping the full-string NSRange arg AND
    /// the leading `try!` (the shim does not throw — the throwing init becomes a host call).
    func testRewritesNSRegexNumberOfMatches() {
        let src = "let n = try! NSRegularExpression(pattern: p).numberOfMatches(in: text, range: NSRange(location: 0, length: text.count))"
        let r = FusionRewriter().rewrite(src)
        XCTAssertTrue(r.bridgedLeaves.contains("NSRegularExpression.numberOfMatches"))
        XCTAssertEqual(r.source, "let n = _patchFusionRegexCount(text, p)")
        XCTAssertFalse(r.source.contains("NSRegularExpression"), "no ICU type token may remain")
        XCTAssertFalse(r.source.contains("try"), "the dangling `try!` must be consumed (shim doesn't throw)")
    }

    /// `try! NSRegularExpression(pattern:).firstMatch(in:range:) != nil` → the Bool test
    /// shim (the `try!` is consumed; `NSRange(s.startIndex..., in: s)` one-level nest matched).
    func testRewritesNSRegexFirstMatchNotNil() {
        let src = #"let ok = try! NSRegularExpression(pattern: "[A-Z]+").firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil"#
        let r = FusionRewriter().rewrite(src)
        XCTAssertTrue(r.bridgedLeaves.contains("String.range(of:options:.regularExpression)"))
        XCTAssertEqual(r.source, #"let ok = _patchFusionRegexTest(s, "[A-Z]+")"#)
    }

    /// `try! NSRegularExpression(pattern:).stringByReplacingMatches(in:range:withTemplate:)`
    /// → the ICU template replace shim.
    func testRewritesNSRegexStringByReplacingMatches() {
        let src = "let out = try! NSRegularExpression(pattern: pat).stringByReplacingMatches(in: input, range: NSRange(location: 0, length: input.count), withTemplate: tmpl)"
        let r = FusionRewriter().rewrite(src)
        XCTAssertTrue(r.bridgedLeaves.contains("String.replacingOccurrences(of:with:.regularExpression)"))
        XCTAssertEqual(r.source, "let out = _patchFusionRegexReplace(input, pat, tmpl)")
    }

    /// A regex call FORM inside a string literal must NOT be rewritten (code-mask guard).
    func testDoesNotRewriteRegexInsideStringLiteral() {
        let src = #"let doc = "use s.range(of: p, options: .regularExpression) != nil to test""#
        let r = FusionRewriter().rewrite(src)
        XCTAssertFalse(r.didRewrite)
        XCTAssertEqual(r.source, src)
    }

    /// The regex shims are pure scalar/String (Bool/Int/String) → they must NOT pull
    /// Foundation (they stay T0 — no Foundation value type crosses the boundary).
    func testRegexShimsAreT0NoFoundation() {
        let rw = FusionRewriter()
        let s = rw.swiftBridgeSource(for: rw.bridges(forLeaves: [
            "String.range(of:options:.regularExpression)",
            "String.replacingOccurrences(of:with:.regularExpression)",
            "NSRegularExpression.numberOfMatches",
            "NSRegularExpression.firstMatch.capture",
        ]), cTargetName: "FusionCHost")
        XCTAssertTrue(s.contains("func _patchFusionRegexTest"))
        XCTAssertTrue(s.contains("func _patchFusionRegexReplace"))
        XCTAssertTrue(s.contains("func _patchFusionRegexCount"))
        XCTAssertTrue(s.contains("func _patchFusionRegexCapture"))
        XCTAssertFalse(s.contains("import Foundation"),
                       "the regex shims are pure scalar/String → T0, no Foundation")
    }

    /// The regex header declares the flat patch_host imports with the EXACT module+name
    /// the SDK's FoundationBridge registers.
    func testRegexHeaderDeclaresFlatPatchHostImports() {
        let rw = FusionRewriter()
        let h = rw.headerSource(for: rw.bridges(forLeaves: [
            "String.range(of:options:.regularExpression)",
            "String.replacingOccurrences(of:with:.regularExpression)",
            "NSRegularExpression.numberOfMatches",
            "NSRegularExpression.firstMatch.capture",
        ]))
        XCTAssertTrue(h.contains(#"WASM_IMPORT("patch_host","regex_test")"#))
        XCTAssertTrue(h.contains(#"WASM_IMPORT("patch_host","regex_replace")"#))
        XCTAssertTrue(h.contains(#"WASM_IMPORT("patch_host","regex_count")"#))
        XCTAssertTrue(h.contains(#"WASM_IMPORT("patch_host","regex_capture")"#))
        XCTAssertTrue(h.contains("int32_t patch_regex_test(const uint8_t* str, int32_t strLen,"))
    }

    /// A representative fused validator: regex-test an input + regex-clean it. Both
    /// leaves lower; no `NSRegularExpression` / `.regularExpression` token remains.
    func testRewritesFusedRegexValidator() {
        let src = """
        func sanitize(_ input: String) -> String? {
            guard input.range(of: "^[A-Za-z0-9 ]+$", options: .regularExpression) != nil else { return nil }
            return input.replacingOccurrences(of: "\\\\s+", with: " ", options: .regularExpression)
        }
        """
        let r = FusionRewriter().rewrite(src)
        XCTAssertTrue(r.bridgedLeaves.contains("String.range(of:options:.regularExpression)"))
        XCTAssertTrue(r.bridgedLeaves.contains("String.replacingOccurrences(of:with:.regularExpression)"))
        XCTAssertTrue(r.source.contains("_patchFusionRegexTest(input,"))
        XCTAssertTrue(r.source.contains("_patchFusionRegexReplace(input,"))
        XCTAssertFalse(r.source.contains(".regularExpression"))
    }

    // MARK: - BUG R2-#101: block-comment quotes must not open a phantom string

    /// A block comment containing a SINGLE `"` must NOT open a phantom string region
    /// that swallows the real bridge-call code that follows. Before the fix the lone
    /// `"` inside `/* it's a " here */` opened a string that masked everything up to
    /// the next `"`, hiding the legitimate `Locale.current.identifier` rewrite.
    func testBlockCommentSingleQuoteDoesNotMaskFollowingCode() {
        let src = """
        func id() -> String {
            /* it's a " here */
            let id = Locale.current.identifier
            return id
        }
        """
        let r = FusionRewriter().rewrite(src)
        XCTAssertTrue(r.bridgedLeaves.contains("Locale.current.identifier"),
                      "a block-comment quote must not mask the following Locale rewrite; got:\n\(r.source)")
        XCTAssertTrue(r.source.contains("_patchFusionLocaleIdentifier()"),
                      "the real call after the block comment must be rewritten; got:\n\(r.source)")
    }

    /// A bridge call FORM that appears INSIDE a block comment is correctly left
    /// un-rewritten (its head is masked) — the mask models block comments as data.
    func testBlockCommentCallFormIsNotRewritten() {
        let src = """
        func id() -> String {
            /* sample: Locale.current.identifier */
            return "x"
        }
        """
        let r = FusionRewriter().rewrite(src)
        XCTAssertFalse(r.bridgedLeaves.contains("Locale.current.identifier"),
                       "a call form inside a block comment must NOT be rewritten; got:\n\(r.source)")
        XCTAssertEqual(r.source, src, "block-comment-only content passes through byte-identical")
    }

    /// `codeMask` masks the block-comment body false (and its content can't open a
    /// string), while the code AFTER `*/` stays unmasked (true) so it is rewritable.
    func testCodeMaskModelsBlockComments() {
        let s = #"/* a " b */ let x = 1"#
        let mask = FusionRewriter.codeMask(s)
        let u = Array(s.utf16)
        // Every offset inside the comment (up to and including the closing `*/`) is masked.
        let closeIdx = s.range(of: "*/").map { s.utf16.distance(from: s.utf16.startIndex, to: $0.upperBound) }!
        for i in 0..<closeIdx { XCTAssertFalse(mask[i], "offset \(i) inside the block comment must be masked") }
        // The `let` after the comment is ordinary code (unmasked).
        let letIdx = s.range(of: "let").map { s.utf16.distance(from: s.utf16.startIndex, to: $0.lowerBound) }!
        XCTAssertTrue(mask[letIdx], "code after the block comment must be unmasked")
        XCTAssertEqual(mask.count, u.count)
    }

    // MARK: - BUG R2-#107: NumberFormatter builder rewrite fires

    /// The documented NumberFormatter builder (explicit, EQUAL min/max fraction
    /// digits) collapses to the `_patchFusionNumberFormat` shim, wrapped `Optional(...)`
    /// so the developer's `?? ""` still type-checks. `numberFormatStyled` is no longer
    /// a documented-but-dead leaf (the bug).
    func testRewritesNumberFormatterCurrencyBuilder() {
        let src = """
        func price(_ amount: Double) -> String {
            let f = NumberFormatter()
            f.numberStyle = .currency
            f.minimumFractionDigits = 2
            f.maximumFractionDigits = 2
            return f.string(from: NSNumber(value: amount)) ?? ""
        }
        """
        let r = FusionRewriter().rewrite(src)
        XCTAssertTrue(r.bridgedLeaves.contains("NumberFormatter.string(from:)"),
                      "the NumberFormatter builder must lower; got:\n\(r.source)")
        XCTAssertFalse(r.source.contains("NumberFormatter"),
                       "no formatter token may remain; got:\n\(r.source)")
        XCTAssertTrue(r.source.contains("return Optional(_patchFusionNumberFormat(Double(amount), _patchFusionNumStyle_currency, Int32(2), \"\")) ?? \"\""),
                      "currency style, frac=2, value wrapped Double(), Optional-wrapped so `?? \"\"` survives; got:\n\(r.source)")
    }

    /// The other property ordering (max before min) also matches.
    func testRewritesNumberFormatterDecimalBuilderMaxFirst() {
        let src = """
        func num(_ v: Int) -> String? {
            let nf = NumberFormatter()
            nf.numberStyle = .decimal
            nf.maximumFractionDigits = 1
            nf.minimumFractionDigits = 1
            return nf.string(from: NSNumber(value: v))
        }
        """
        let r = FusionRewriter().rewrite(src)
        XCTAssertTrue(r.bridgedLeaves.contains("NumberFormatter.string(from:)"))
        XCTAssertTrue(r.source.contains("return Optional(_patchFusionNumberFormat(Double(v), _patchFusionNumStyle_decimal, Int32(1), \"\"))"),
                      "decimal style, max-then-min ordering, frac=1; got:\n\(r.source)")
    }

    /// FIDELITY/demote-safety: a builder OMITTING the fraction digits is NOT matched
    /// (the SDK shim would force integer-only output) → stays native, demotes alone.
    func testDoesNotRewriteNumberFormatterWithoutFractionDigits() {
        let src = """
        func price(_ amount: Double) -> String {
            let f = NumberFormatter()
            f.numberStyle = .currency
            return f.string(from: NSNumber(value: amount)) ?? ""
        }
        """
        let r = FusionRewriter().rewrite(src)
        XCTAssertFalse(r.bridgedLeaves.contains("NumberFormatter.string(from:)"),
                       "no explicit fraction digits → not faithfully representable → not rewritten; got:\n\(r.source)")
        XCTAssertTrue(r.source.contains("NumberFormatter"),
                      "the unmatched builder is left verbatim (demote-safe)")
    }

    /// FIDELITY: UNEQUAL min/max fraction digits is NOT matched (the shim applies one
    /// value to both) → stays native (demote-safe).
    func testDoesNotRewriteNumberFormatterUnequalFractionDigits() {
        let src = """
        func price(_ amount: Double) -> String {
            let f = NumberFormatter()
            f.numberStyle = .currency
            f.minimumFractionDigits = 0
            f.maximumFractionDigits = 2
            return f.string(from: NSNumber(value: amount)) ?? ""
        }
        """
        let r = FusionRewriter().rewrite(src)
        XCTAssertFalse(r.bridgedLeaves.contains("NumberFormatter.string(from:)"),
                       "unequal min/max (0 vs 2) is not faithfully representable → not rewritten; got:\n\(r.source)")
    }

    // MARK: - Helpers

    private func makePipeline() -> BuildPipeline {
        BuildPipeline(registry: .standard)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FusionTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
