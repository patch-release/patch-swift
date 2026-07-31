// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The packaging tier a WASM-bound module/function is built at — the smallest
/// viable Swift→WASM SDK that can compile it. Drives `BuildPipeline` tier
/// selection (see `research/module-size/tiered-packaging/FINDINGS.md`).
///
///  - `t0Embedded`  — Embedded Swift (`swift-6.3.2-RELEASE_wasm-embedded`), no
///    Foundation/ICU in the module. Foundation *values* (Decimal/JSON/Date) are
///    satisfied by **host bridges** (the native shell's real Foundation). Size:
///    tens of KB. The DEFAULT, by far the smallest.
///  - `t1Stdlib`    — full WASM SDK but no `import Foundation`; stdlib runtime
///    only (~1.1 MB brotli). For code that needs stdlib features Embedded rejects
///    (e.g. `any` existentials) but no Foundation.
///  - `t2Foundation`— full WASM SDK with `import Foundation`; statically links
///    Foundation + ICU (~11.7 MB brotli). The fallback when a module truly needs
///    in-module Foundation (e.g. `Mirror`, `NSRegularExpression`) that no bridge
///    covers.
public enum PackagingTier: String, Sendable, Codable, Hashable, CaseIterable, Comparable {
    case t0Embedded
    case t1Stdlib
    case t2Foundation

    /// Ordered smallest → largest, so `min`/`<` pick the smaller (better) tier.
    private var order: Int {
        switch self {
        case .t0Embedded: return 0
        case .t1Stdlib: return 1
        case .t2Foundation: return 2
        }
    }
    public static func < (lhs: PackagingTier, rhs: PackagingTier) -> Bool {
        lhs.order < rhs.order
    }

    /// The Swift SDK identifier for this tier.
    public var swiftSDK: String {
        switch self {
        case .t0Embedded: return "swift-6.3.2-RELEASE_wasm-embedded"
        case .t1Stdlib, .t2Foundation: return "swift-6.3.2-RELEASE_wasm"
        }
    }

    /// Approximate brotli floor (for reports / tier choice rationale).
    public var approxBrotliFloor: String {
        switch self {
        case .t0Embedded: return "tens of KB"
        case .t1Stdlib: return "~1.1 MB"
        case .t2Foundation: return "~11.7 MB"
        }
    }
}

/// Static **embedded-compatibility** analysis: decides, conservatively, whether
/// a WASM-eligible function can compile under **Embedded Swift** (T0) — and, if
/// not, the smallest tier that can hold it (T1 stdlib, T2 Foundation).
///
/// This is the classifier's "embedded axis" (research SYNTHESIS step 1c). It is
/// purely static + conservative: when unsure a construct is embeddable, it falls
/// back to a larger tier — never producing a broken (won't-compile) module. The
/// `BuildPipeline`'s compile-oracle + auto-demote loop is the second safety net.
///
/// ## What Embedded Swift rejects (from `tiered-packaging/FINDINGS.md`)
///  - `import Foundation` *in the module*: there is no `Foundation` module for
///    embedded → hard error. BUT Foundation **values** (Decimal/JSON/Date) are
///    provided by **host bridges**, so a function that only needs those values
///    can still be T0 — the codegen routes them through the C-header bridge
///    instead of `import Foundation`.
///  - `any Protocol` existentials → `#EmbeddedRestrictions` error.
///  - `Mirror` / reflection → no runtime metadata.
///  - `AnyObject` / `AnyClass` / metatypes (`.Type`, `.self` as a value, `type(of:)`).
///  - in-module `Codable` **synthesis** (`JSONEncoder`/`JSONDecoder`/derived
///    `Encodable`/`Decodable`) → bridged to the host instead.
///  - unspecializable generics (can't be monomorphized) — approximated here by
///    generic existential use; the compile oracle is the ground truth.
public struct EmbeddedCompatibility: Sendable {
    public init() {}

    /// The outcome of analyzing one function for embedded-compatibility.
    public struct Verdict: Sendable, Hashable {
        /// The smallest tier the function can be packaged at.
        public let tier: PackagingTier
        /// True iff the function is embeddable (tier == t0Embedded).
        public var isEmbeddable: Bool { tier == .t0Embedded }
        /// Embedded-incompatible constructs found (empty when embeddable).
        public let blockers: [String]
        /// Foundation-value symbols that WILL be routed through host bridges in T0
        /// (Decimal/JSON/Date) — informational, NOT blockers.
        public let bridgedFoundation: [String]
        public init(tier: PackagingTier, blockers: [String], bridgedFoundation: [String]) {
            self.tier = tier
            self.blockers = blockers
            self.bridgedFoundation = bridgedFoundation
        }
    }

    // MARK: - Symbol tables

    /// Foundation **value** symbols satisfiable by the host bridges (so their use
    /// does NOT block T0 — codegen routes them through `patch_host.*`).
    static let bridgedFoundationValues: Set<String> = [
        "Decimal", "NSDecimalNumber", "NSDecimalRound",
        "Date", "TimeInterval",
        "JSONSerialization",
    ]

    /// Symbols/constructs Embedded Swift CANNOT compile (no bridge possible) →
    /// force a fall back out of T0. Matched against reference names AND a base.
    static let embeddedBlockerSymbols: Set<String> = [
        // Reflection — no runtime metadata in embedded.
        "Mirror",
        // Metatype / dynamic typing.
        "AnyObject", "AnyClass", "AnyHashable",
        // In-module Codable synthesis + JSON coders (bridge JSON via host instead).
        "JSONEncoder", "JSONDecoder", "PropertyListEncoder", "PropertyListDecoder",
        "Codable", "Encodable", "Decodable",
        // Foundation types with no value-bridge that pull ICU/runtime.
        "NSRegularExpression", "NumberFormatter", "DateFormatter",
        "ISO8601DateFormatter", "RelativeDateTimeFormatter", "Calendar", "Locale", "TimeZone",
        "NSObject", "NSString", "NSNumber", "NSArray", "NSDictionary",
        // Foundation networking/IO (these are also mustStayNative, but list here
        // so the embedded axis is self-contained when called on raw sources).
        "FileManager", "URLSession",
    ]

    // MARK: - Function-level analysis (reference based)

    /// Analyze a single function from its parsed references. Used by the
    /// classifier per WASM-eligible function. `usesFoundationImport` lets the
    /// caller pass the file-level grep result (`import Foundation`), which only
    /// matters if a real blocker symbol is also present — Foundation-value-only
    /// code is still T0 via bridges.
    public func analyze(references: [Reference], reasonsPrefix: String = "") -> Verdict {
        var blockers: [String] = []
        var bridged: [String] = []
        var sawExistential = false
        var sawMetatype = false

        for ref in references {
            let name = ref.name
            let base = ref.base
            // Bridged Foundation values: informational, not a blocker.
            if Self.bridgedFoundationValues.contains(name) ||
               (base.map(Self.bridgedFoundationValues.contains) ?? false) {
                bridged.append(name)
                continue
            }
            // Hard embedded blockers.
            if Self.embeddedBlockerSymbols.contains(name) ||
               (base.map(Self.embeddedBlockerSymbols.contains) ?? false) {
                blockers.append("\(reasonsPrefix)uses `\(name)` — not available in Embedded Swift")
            }
            // `any P` existentials surface in references as an identifier `any`
            // or a type name prefixed with `any `.
            if name == "any" || name.hasPrefix("any ") {
                sawExistential = true
            }
            // Metatype use: `.self` / `.Type` / `type(of:)`.
            if name == "type(of:)" || name.hasSuffix(".self") || name.hasSuffix(".Type")
                || name == ".self" || name == ".Type" {
                sawMetatype = true
            }
        }
        if sawExistential {
            blockers.append("\(reasonsPrefix)uses `any` existential — rejected by Embedded Swift")
        }
        if sawMetatype {
            blockers.append("\(reasonsPrefix)uses a metatype (`.self`/`.Type`/`type(of:)`) — rejected by Embedded Swift")
        }

        return decide(blockers: blockers, bridged: bridged)
    }

    // MARK: - Source-text analysis (for sources / the file grep oracle)

    /// Static tier decision over raw Swift source — the textual counterpart of the
    /// research `classify-tier.sh` grep rules, used by `BuildPipeline` before the
    /// compile oracle and by tests. Conservative: any blocker token → fall back.
    ///
    /// Decision (mirrors SYNTHESIS / classify-tier.sh):
    ///   1. real embedded blocker (Mirror/Codable-synth/existential/metatype/…)
    ///      that is NOT a bridged Foundation value → T1 (or T2 if it needs
    ///      in-module Foundation), else
    ///   2. T0 Embedded (Foundation-free, or Foundation-values-via-bridge only).
    public func analyzeSource(_ source: String) -> Verdict {
        var blockers: [String] = []
        var bridged: [String] = []

        // Strip comments AND string literals before token matching. A blocker token
        // (`Codable`, `Mirror`, `Locale`, …) that appears ONLY inside a `/* */` block
        // comment, a `//` line comment, or a string literal is NOT real code — and a
        // single such false hit used to promote the WHOLE module from T0 (~tens of KB)
        // to T2 (~60 MB full Foundation). The old code stripped only `//`, so a doc
        // block comment ("does not use Codable") or a label string ("choose a Locale")
        // silently ballooned the module. (real `///` doc lines worked only by accident,
        // because they start with `//`.)
        let code = Self.stripCommentsAndStrings(source)

        // `any <Capitalized>` existentials (allow `Any` the type, block `any P`).
        if rangesOf(#"\bany\s+[A-Z]"#, in: code) { blockers.append("`any P` existential — rejected by Embedded Swift") }

        for sym in Self.embeddedBlockerSymbols where containsIdentifier(sym, in: code) {
            blockers.append("uses `\(sym)` — not available in Embedded Swift")
        }
        // Reflection / metatypes textual probes.
        if rangesOf(#"\btype\(of:"#, in: code) { blockers.append("`type(of:)` — rejected by Embedded Swift") }
        if rangesOf(#"\b\w+\.self\b"#, in: code) { blockers.append("metatype `.self` — rejected by Embedded Swift") }

        for sym in Self.bridgedFoundationValues where containsIdentifier(sym, in: code) {
            bridged.append(sym)
        }
        return decide(blockers: blockers, bridged: bridged)
    }

    // MARK: - Decision

    private func decide(blockers: [String], bridged: [String]) -> Verdict {
        let uniqueBlockers = dedupe(blockers)
        let uniqueBridged = dedupe(bridged)
        if uniqueBlockers.isEmpty {
            // Embeddable: pure logic, or Foundation values that the host bridges
            // supply (Decimal/JSON/Date). The DEFAULT, smallest tier.
            return Verdict(tier: .t0Embedded, blockers: [], bridgedFoundation: uniqueBridged)
        }
        // A blocker → fall back. If the only blockers are stdlib-level
        // (existential / metatype / AnyObject) the function fits T1 (stdlib, no
        // Foundation). If it needs in-module Foundation (Codable synthesis,
        // formatters, NSRegularExpression, NS* types) it needs T2.
        let needsFoundation = uniqueBlockers.contains { b in
            Self.t2OnlyBlockerHints.contains { b.contains($0) }
        }
        return Verdict(tier: needsFoundation ? .t2Foundation : .t1Stdlib,
                       blockers: uniqueBlockers, bridgedFoundation: uniqueBridged)
    }

    /// Blocker substrings that require full Foundation (T2), not just stdlib (T1).
    static let t2OnlyBlockerHints: [String] = [
        "JSONEncoder", "JSONDecoder", "PropertyListEncoder", "PropertyListDecoder",
        "Codable", "Encodable", "Decodable",
        "NSRegularExpression", "NumberFormatter", "DateFormatter", "ISO8601DateFormatter",
        "RelativeDateTimeFormatter", "Calendar", "Locale", "TimeZone",
        "NSObject", "NSString", "NSNumber", "NSArray", "NSDictionary", "Mirror",
        "FileManager", "URLSession",
    ]

    // MARK: - Text helpers

    /// Remove `//` line comments, `/* … */` (nested) block comments, and string
    /// literals (`"…"` incl. escapes, plus `"""…"""` multiline) from Swift source so
    /// the embedded-blocker token grep only sees real code. Conservative: replaces
    /// the removed spans with spaces (preserving offsets is unnecessary — only token
    /// presence matters). Not a full lexer, but covers the cases that caused false
    /// T2 promotion (a blocker word in prose or a label string).
    static func stripCommentsAndStrings(_ source: String) -> String {
        var out = ""
        out.reserveCapacity(source.count)
        let chars = Array(source)
        var i = 0
        let n = chars.count
        var blockDepth = 0
        while i < n {
            let c = chars[i]
            // Inside a (possibly nested) block comment.
            if blockDepth > 0 {
                if c == "*" && i + 1 < n && chars[i + 1] == "/" { blockDepth -= 1; i += 2; continue }
                if c == "/" && i + 1 < n && chars[i + 1] == "*" { blockDepth += 1; i += 2; continue }
                i += 1
                continue
            }
            // Start of a block comment.
            if c == "/" && i + 1 < n && chars[i + 1] == "*" { blockDepth = 1; i += 2; continue }
            // Line comment → skip to end of line.
            if c == "/" && i + 1 < n && chars[i + 1] == "/" {
                while i < n && chars[i] != "\n" { i += 1 }
                continue
            }
            // Multiline string literal `"""..."""`.
            if c == "\"" && i + 2 < n && chars[i + 1] == "\"" && chars[i + 2] == "\"" {
                i += 3
                while i < n {
                    if chars[i] == "\"" && i + 2 < n && chars[i + 1] == "\"" && chars[i + 2] == "\"" {
                        i += 3; break
                    }
                    i += 1
                }
                out.append(" ")
                continue
            }
            // Single-line string literal `"..."` (honor `\"` escapes).
            if c == "\"" {
                i += 1
                while i < n {
                    if chars[i] == "\\" { i += 2; continue }
                    if chars[i] == "\"" { i += 1; break }
                    if chars[i] == "\n" { break }   // unterminated — stop at newline
                    i += 1
                }
                out.append(" ")
                continue
            }
            out.append(c)
            i += 1
        }
        return out
    }

    private func rangesOf(_ pattern: String, in text: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return re.firstMatch(in: text, range: range) != nil
    }

    /// Word-boundary identifier match (avoids matching `Decimalish` for `Decimal`).
    private func containsIdentifier(_ identifier: String, in text: String) -> Bool {
        rangesOf("\\b" + NSRegularExpression.escapedPattern(for: identifier) + "\\b", in: text)
    }

    private func dedupe(_ xs: [String]) -> [String] {
        var seen = Set<String>(); var out: [String] = []
        for x in xs where seen.insert(x).inserted { out.append(x) }
        return out
    }
}
