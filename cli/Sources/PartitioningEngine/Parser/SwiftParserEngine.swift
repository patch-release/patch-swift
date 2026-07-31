// SPDX-License-Identifier: Apache-2.0

import Foundation
import SwiftSyntax
import SwiftParser

/// Parses a directory (or single file) of `.swift` sources into `FunctionRecord`s.
///
/// This is Agent A1 scope. It walks every `.swift` file, and for every
/// function decl, method, initializer, computed property and closure literal,
/// emits a `FunctionRecord` capturing the body references the call graph and
/// classifier need.
public struct SwiftParserEngine {
    public init() {}

    /// Parse every `.swift` file under `directory` (recursively).
    public func parseDirectory(_ directory: URL) throws -> [FunctionRecord] {
        let files = try Self.swiftFiles(in: directory)
        var records: [FunctionRecord] = []
        for file in files {
            // Resilient: an unreadable/odd-encoding file (test fixtures, symlinks,
            // non-UTF-8) should not abort analysis of the whole corpus app. Skip
            // it conservatively — a skipped file only lowers coverage, never
            // breaks safety.
            if let recs = try? parseFile(file) {
                records.append(contentsOf: recs)
            }
        }
        return records
    }

    /// Parse a single `.swift` file into function records. Falls back to a
    /// lenient encoding read so a stray non-UTF-8 byte doesn't throw.
    public func parseFile(_ file: URL) throws -> [FunctionRecord] {
        let source: String
        if let utf8 = try? String(contentsOf: file, encoding: .utf8) {
            source = utf8
        } else {
            // Lenient fallback: read raw bytes and decode permissively.
            let data = try Data(contentsOf: file)
            source = String(decoding: data, as: UTF8.self)
        }
        return parse(source: source, file: file)
    }

    /// Parse source text directly (used heavily by tests).
    public func parse(source: String, file: URL) -> [FunctionRecord] {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: file.path, tree: tree)
        // Module name: derive from the file's parent directory, falling back to "Module".
        let module = file.deletingLastPathComponent().lastPathComponent
        let visitor = FunctionExtractor(
            moduleName: module.isEmpty ? "Module" : module,
            file: file,
            converter: converter
        )
        visitor.walk(tree)
        return visitor.records
    }

    /// Recursively enumerate `.swift` files under a directory. If `directory`
    /// is itself a `.swift` file, returns just that file.
    static func swiftFiles(in directory: URL) throws -> [URL] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDir) else {
            throw ParserError.pathNotFound(directory)
        }
        if !isDir.boolValue {
            return directory.pathExtension == "swift" ? [directory] : []
        }
        var result: [URL] = []
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            // [BUG-1] Never ingest the engine's OWN prior-run output. `Patch
            // build`/`release` write generated sources into `.Patch/build`
            // (`_PatchType_*.swift`, `_PatchHelper_*.swift`, `_PatchGenerics.swift`,
            // `_PatchNamespaces.swift`, `_PatchRuntime.swift`, …). Those carry the
            // RECONSTRUCTED bodies from the LAST build; re-analyzing them as if they
            // were developer source poisons classification/bundling so a re-release
            // after a source edit can re-emit the OLD function body (silent
            // wrong-code OTA). A clean build is correct only because nothing stale
            // exists. The `_wasm.swift`/`_bridge.swift` skip below was not enough —
            // the support files do not carry those suffixes. (`.swiftpm` is Xcode's
            // package metadata dir, also never developer logic.)
            let lowerPath = url.path.lowercased()
            if lowerPath.contains("/.patch/") || lowerPath.contains("/.swiftpm/") { continue }
            if Self.isBuildArtifactPath(lowerPath) { continue }
            // Skip generated split outputs so re-runs are idempotent.
            let name = url.lastPathComponent
            if name.hasSuffix("_wasm.swift") || name.hasSuffix("_bridge.swift") { continue }
            // [BUG-1] The `/.patch/` location skip above is defeated by a custom
            // `--output` dir: the engine's OWN generated support sources
            // (`_PatchFusionShims`/`_PatchHelper_*`/`_PatchNamespaces`/`_PatchType_*`/
            // `_PatchGenerics`/`_PatchRuntime`) written into a relocated output dir get
            // walked as developer Swift → fingerprint churn AND re-analysis of the
            // RECONSTRUCTED bodies (a silent stale-body wrong-code OTA hazard). Skip the
            // generated `_Patch*` family by NAME so the exclusion is location-independent.
            if name.hasPrefix("_Patch") { continue }
            // Fix B: exclude TEST targets/files from OTA eligibility. XCTest /
            // swift-testing (`@Test`/`#expect`) / `XCUIApplication` symbols can't be
            // bundled (no WASM SDK) and must never be shipped as OTA fragments (the
            // triage's swift-testing-macro-gap bucket). Detect by path + content and
            // skip so test symbols never enter the classifier/codegen at all.
            if isTestFile(url) { continue }
            result.append(url)
        }
        return result.sorted { $0.path < $1.path }
    }

    /// Whether a `.swift` file is test code (excluded from OTA eligibility, Fix B).
    /// Path-based first (a `/Tests/`/`/UITests/` segment, or a `*Tests.swift` /
    /// `*Test.swift` / `*Spec.swift` filename), then a content sniff for the test
    /// imports/symbols that can't be bundled. Conservative: a false positive only
    /// lowers coverage; a false negative would try to ship an un-bundlable test
    /// symbol, so we err toward detecting.
    /// True when a path lives inside build-tool OUTPUT that sits in the project
    /// tree — Xcode DerivedData (esp. `-derivedDataPath ./DerivedData`), resolved
    /// SwiftPM dependency clones (`SourcePackages/checkouts`), CocoaPods, Carthage,
    /// node_modules. Project-discovery walks MUST skip these: ingesting the
    /// thousands of transitive-dependency sources there hangs SwiftSyntax
    /// classification at 100% CPU and destabilises the native-shell fingerprint.
    /// `path` should already be lowercased.
    public static func isBuildArtifactPath(_ lowercasedPath: String) -> Bool {
        lowercasedPath.contains("/deriveddata/")
            || lowercasedPath.contains("/sourcepackages/")
            || lowercasedPath.contains("/checkouts/")
            || lowercasedPath.contains("/carthage/")
            || lowercasedPath.contains("/pods/")
            || lowercasedPath.contains("/node_modules/")
            // Xcode build OUTPUT placed in-tree (e.g. `-derivedDataPath ./build`, as
            // xcodegen/Tuist projects commonly do). `.noindex` is Apple's build-dir
            // marker (Spotlight-excluded) — `Build/Intermediates.noindex/…` holds
            // per-target `*.build` clones + generated sources (GeneratedAssetSymbols,
            // resource_bundle_accessor); `Build/Products/<platform>/…` holds compiled
            // headers/FFI. Both regenerate on EVERY build, so hashing them churned the
            // fingerprint even after dependency clones were excluded. (DerivedData NOT
            // in `./build` is already caught by `/deriveddata/`.)
            || lowercasedPath.contains(".noindex/")
            || lowercasedPath.contains("/build/products/")
    }

    public static func isTestFile(_ url: URL) -> Bool {
        let lowerPath = url.path.lowercased()
        if lowerPath.contains("/tests/") || lowerPath.contains("/uitests/")
            || lowerPath.contains("/unittests/") || lowerPath.contains("/test/") {
            return true
        }
        let name = url.deletingPathExtension().lastPathComponent
        // Basename test-suffix detection. The PLURAL `*Tests`/`*UITests` (Xcode-generated) and
        // `*Spec` (Quick/Nimble — those files import Quick, NOT XCTest, so the content sniff below
        // would MISS them, and letting one into the WASM compile breaks it) are strong test signals
        // → exclude by name. The SINGULAR `*Test` (`ABTest`, `SpeedTest`, `LoadTest`) is genuine
        // NATIVE app code far more often than a test, and excluding it makes a real native-shell
        // edit invisible to the fingerprint (false-stable, R2-#37) → require corroboration (a test
        // path segment, handled above, OR a test import via the content sniff below).
        if name.hasSuffix("Tests") || name.hasSuffix("UITests") || name.hasSuffix("Spec") {
            return true
        }
        // Content sniff (additive): catch a test file (incl. a singular-`Test` one) by its imports.
        guard let src = (try? String(contentsOf: url, encoding: .utf8))
                ?? (try? Data(contentsOf: url)).map({ String(decoding: $0, as: UTF8.self) }) else {
            return false
        }
        return sourceLooksLikeTest(src)
    }

    /// Content-only test detection (exposed for unit testing without a file on disk).
    /// Looks for the test frameworks/symbols that cannot ride OTA (no WASM SDK).
    public static func sourceLooksLikeTest(_ source: String) -> Bool {
        for marker in ["import XCTest", "import Testing",
                       "XCTestCase", "XCUIApplication", "XCTMain"]
        where source.contains(marker) { return true }
        // swift-testing `@Test`/`@Suite` attribute or `#expect`/`#require` macro.
        for marker in ["@Test ", "@Test(", "@Test\n", "@Suite ", "@Suite(", "#expect(", "#require("]
        where source.contains(marker) { return true }
        return false
    }
}

public enum ParserError: Error, CustomStringConvertible {
    case pathNotFound(URL)

    public var description: String {
        switch self {
        case .pathNotFound(let url):
            return "Path not found: \(url.path)"
        }
    }
}
