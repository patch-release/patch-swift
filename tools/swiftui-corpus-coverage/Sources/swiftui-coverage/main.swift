import Foundation
import CodeGenerator
import ViewNodeIR
import Compiler

// =============================================================================
// SwiftUI-lowering CORPUS COVERAGE census.
//
// For each app directory passed (or listed in a manifest), this walks the
// developer's REAL Swift sources, runs the engine's `BodyLowering.lowerAllViews`
// over every file, and decides — per `: View` struct — whether it LOWERS (the
// production auto-route verdict: emitted AND `thunkSafe` AND not reading an
// unmarshalled input) or DEMOTES to native. It then ranks WHY views demote.
//
// This is a READ-ONLY census of the apps; it never compiles to WASM (the static
// classification + emission is the verdict, and it's fast).
//
// Verdict logic mirrors `Compiler/BuildPipeline.runSwiftUILowering` EXACTLY:
//   • EXCLUDED (native, not patchable) if `referencesUnmarshalledInput`.
//   • else `thunkSafe = opaqueLeaves.allSatisfy { $0.slotable } && report.hasLoweredContentNode`.
//   • a view with 0 classified elements is nothing to ship (skipped/native).
// A view "LOWERS" (the headline) iff it is emitted, thunkSafe, and not excluded.
// =============================================================================

// MARK: - Source discovery (developer source only — NOT deps/generated/derived)

/// Path fragments that mark NON-developer Swift we must exclude from the census:
/// SwiftPM checkouts, build/derived output, Pods, Carthage, and Patch's own
/// generated thunk/IR sources. Measuring these would inflate or pollute the count.
let excludedPathFragments: [String] = [
    "/.build/", "/build/", "/DerivedData/", "/.swiftpm/",
    "/SourcePackages/", "/checkouts/", "/Pods/", "/Carthage/",
    "/.Patch/", "/Patch.generated/", "/.git/",
    "/Tests/", "/Test/", "/UITests/", "/Snapshot",
    "/Generated/", "/__Snapshots__/",
]

/// Filename suffixes that indicate generated / test / non-app Swift.
let excludedFileSuffixes: [String] = [
    "_wasm.swift", "_bridge.swift",
    "Tests.swift", "Test.swift", "Spec.swift",
    ".generated.swift", "+Generated.swift",
]

func isDeveloperSwift(_ url: URL) -> Bool {
    let p = url.path
    guard p.hasSuffix(".swift") else { return false }
    for frag in excludedPathFragments where p.contains(frag) { return false }
    let name = url.lastPathComponent
    for suf in excludedFileSuffixes where name.hasSuffix(suf) { return false }
    // Skip the generated PatchSwiftUI wrapper / IR even if it escaped the .Patch dir.
    if name.hasPrefix("_PatchSwiftUI") || name.hasPrefix("_ViewNodeIR") { return false }
    if name.hasPrefix("PatchThunks") || name.hasPrefix("_PatchType_") { return false }
    return true
}

func developerSwiftFiles(in root: URL) -> [URL] {
    var out: [URL] = []
    let fm = FileManager.default
    guard let en = fm.enumerator(at: root,
                                 includingPropertiesForKeys: [.isRegularFileKey],
                                 options: [.skipsHiddenFiles]) else { return out }
    for case let url as URL in en {
        // Prune obviously-excluded directories cheaply.
        if url.hasDirectoryPath {
            let dn = url.lastPathComponent
            if dn == ".build" || dn == "build" || dn == "DerivedData"
                || dn == "Pods" || dn == "Carthage" || dn == ".Patch"
                || dn == "checkouts" || dn == "SourcePackages" || dn == ".git" {
                en.skipDescendants()
            }
            continue
        }
        if isDeveloperSwift(url) { out.append(url) }
    }
    return out.sorted { $0.path < $1.path }
}

// MARK: - Demote-reason taxonomy

/// The PRIMARY (first blocking) reason a view demotes, normalized into a small,
/// rankable taxonomy. The exact engine string is kept too (for the histogram /
/// examples), but the bucket is what we rank — so "non-constructor call" on a
/// `Theme.Font.body(15)` and on a `Theme.Colors.accent` roll up together as
/// "custom design-system token (color/font/etc.)" when we can detect the shape.
enum DemoteBucket: String, Codable {
    case unmarshalledInput   = "Reads unmarshalled input (custom value type / view-model / @ObservedObject / model struct)"
    case designSystemToken   = "Custom design-system token in a modifier (Theme.Colors.X / Theme.Font.body(...) / custom Color/Font const)"
    case customChildView     = "Custom child view (non-stdlib View type referenced in the body)"
    case nonSlotableLeaf     = "Non-slotable opaque leaf (references a body-local — thunk can't render it)"
    case pureRouter          = "No lowered content node (pure router / layout shell — nothing patchable)"
    case unsupportedModifier = "Unsupported modifier"
    case computedMember      = "Reads a computed `some View` property / non-view member"
    case leadingDot          = "Leading-dot / non-constructor expression"
    case emptyOrNoBody       = "No classified body (empty / non-lowerable body shape)"
    case other               = "Other (see engine reason)"
}

/// A single demoted-view record.
struct DemoteRecord: Codable {
    let app: String
    let view: String
    let file: String                  // path (Codable-friendly)
    let bucket: DemoteBucket
    let engineReason: String          // the exact engine reason string (or a derived one)
    let snippet: String               // the offending source snippet (best-effort)
}

// MARK: - Per-view verdict

struct ViewVerdict: Codable {
    let app: String
    let view: String
    let file: String
    let lowered: Bool                 // the headline: auto-routes OTA (thunkSafe, emitted, not excluded)
    let elementCoverage: Double       // report.coverage (element-level, secondary)
    let totalElements: Int
    let loweredElements: Int
    let demote: DemoteRecord?         // nil iff lowered
    let elementFallbacks: [String: Int]  // element-level reason -> count (for the histogram)
    // Per-construct detail (for the actionable gap list — the EXACT modifiers/views).
    var unsupportedModifiers: [String] = []   // modifier names that fell back ("resizable", "tag", …)
    var customViews: [String] = []            // custom view type names referenced ("InflammationScoreGauge", …)
}

/// The Codable per-app result a WORKER subprocess emits to stdout. The orchestrator
/// merges these; an app whose worker crashed (a Swift `fatalError` in the engine is
/// a SIGTRAP we can't catch in-process) gets `crashed` set instead of verdicts.
struct AppResult: Codable {
    let app: String
    let path: String
    var verdicts: [ViewVerdict] = []
    var fileCount: Int = 0
    var unreadable: Int = 0
    /// Non-nil iff the worker died (the fatal message captured from its stderr).
    var crashed: String? = nil
}

// MARK: - Snippet helpers

/// Truncate a (possibly multi-line) snippet to one readable line.
func oneLine(_ s: String, max: Int = 110) -> String {
    let collapsed = s.replacingOccurrences(of: "\n", with: " ⏎ ")
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
    if collapsed.count > max { return String(collapsed.prefix(max)) + " …" }
    return collapsed
}

/// Find the first body line that references `token` (a custom view name / a
/// modifier / a design-system token).
func firstLine(containing token: String, in source: String) -> String? {
    for l in source.components(separatedBy: "\n") {
        if l.contains(token) {
            let t = l.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty && !t.hasPrefix("//") { return t }
        }
    }
    return nil
}

/// Best-effort source snippet for a demoting view, driven by the report's
/// classified elements (so we surface the ACTUAL offending construct, by name).
func snippet(for report: LoweringReport, reasonHint: String, in source: String, viewName: String) -> String {
    // 1) A custom child view: find the unlowered node whose name is the custom type.
    if reasonHint.contains("custom/unsupported view type") || reasonHint.contains("child view") {
        if let el = report.elements.first(where: {
            $0.category == .node && !$0.lowered && $0.reason == "custom/unsupported view type"
        }) {
            // strip any `(...)` from the recorded name to get the bare type, then find its call site
            let bare = String(el.name.prefix(while: { $0 != "(" }))
            if let line = firstLine(containing: bare + "(", in: source) { return oneLine(line) }
            if let line = firstLine(containing: bare, in: source) { return oneLine(line) }
            return el.name
        }
    }
    // 2) A token / member / call modifier: surface the offending modifier line.
    if reasonHint.contains("modifier") || reasonHint.contains("member")
        || reasonHint.contains("non-constructor") || reasonHint.contains("leading-dot")
        || reasonHint.contains("token") {
        if let el = report.elements.first(where: { $0.category == .modifier && !$0.lowered }) {
            // el.name is like ".font" / ".foregroundColor" — find that modifier's call line.
            if let line = firstLine(containing: el.name + "(", in: source) { return oneLine(line) }
        }
        // Token hint scan as a fallback.
        for hint in ["Theme.", ".Colors.", ".Font.", "AppColor", "DesignSystem", "Palette.", "Tokens."] {
            if let line = firstLine(containing: hint, in: source) { return oneLine(line) }
        }
    }
    // 3) Fall back to the view's declaration line.
    if let line = firstLine(containing: "struct \(viewName)", in: source) { return oneLine(line) }
    return ""
}

/// Detect whether an engine reason on a modifier is a custom DESIGN-SYSTEM TOKEN
/// reference (the dominant real-app cause). Looks at the offending snippet.
func looksLikeDesignSystemToken(snippet: String) -> Bool {
    let s = snippet
    if s.contains("Theme.") || s.contains("AppColor") || s.contains("AppTheme")
        || s.contains("DesignSystem") || s.contains(".Colors.") || s.contains(".Font.")
        || s.contains("Palette.") || s.contains("Tokens.")
        || s.contains("Color.theme") || s.contains(".theme.")          // Color.theme.X style
        || s.contains("adaptiveFont") || s.contains("adaptivePadding")  // custom DS view-modifiers
    { return true }
    return false
}

// MARK: - Classify a LoweredView into a verdict

func verdict(for lowered: BodyLowering.LoweredView, app: String, file: URL, source: String) -> ViewVerdict {
    let report = lowered.report
    let cov = report.coverage
    let total = report.totalElements
    let loweredEl = report.loweredElements
    let fallbacks = report.fallbackReasons

    // Per-construct detail for the actionable gap list: the EXACT modifier names
    // that fell back, and the custom view type names referenced (de-duped).
    let unsupMods = Array(Set(report.elements
        .filter { $0.category == .modifier && !$0.lowered && $0.reason == "unsupported modifier" }
        .map { $0.name.hasPrefix(".") ? String($0.name.dropFirst()) : $0.name }))
    let customVws = Array(Set(report.elements
        .filter { $0.category == .node && !$0.lowered && $0.reason == "custom/unsupported view type" }
        .map { String($0.name.prefix(while: { $0 != "(" })) }))

    // Empty body — nothing to ship; counts as a non-lowering (native).
    if total == 0 {
        let rec = DemoteRecord(app: app, view: lowered.viewName, file: file.path,
                               bucket: .emptyOrNoBody,
                               engineReason: "empty / no classified body",
                               snippet: snippet(for: report, reasonHint: "", in: source, viewName: lowered.viewName))
        return ViewVerdict(app: app, view: lowered.viewName, file: file.path, lowered: false,
                           elementCoverage: cov, totalElements: total, loweredElements: loweredEl,
                           demote: rec, elementFallbacks: fallbacks,
                           unsupportedModifiers: unsupMods, customViews: customVws)
    }

    // Production verdict, in priority order. MUST mirror BuildPipeline.runSwiftUILowering EXACTLY.
    // (The prior `&& report.hasLoweredContentNode` was STALE/stricter than production: it ignored
    // lowered CONTAINERS/MODIFIERS and the indexed-row/action/effect slots, so it UNDERCOUNTED
    // coverage and inflated the "no lowered content node" bucket with views that actually auto-route.)
    let thunkSafe = lowered.opaqueLeaves.allSatisfy { $0.slotable }
        && (report.hasPatchableLoweredElement || !lowered.indexedRowSlots.isEmpty
            || !lowered.actionSlots.isEmpty || !lowered.effectSlots.isEmpty || !lowered.callbackSlots.isEmpty)
        && !lowered.hasUndispatchableAction
        && !lowered.hasUndispatchableEffect
    let isLowered = !lowered.referencesUnmarshalledInput && !lowered.referencesUnresolvedSymbol && thunkSafe

    if isLowered {
        return ViewVerdict(app: app, view: lowered.viewName, file: file.path, lowered: true,
                           elementCoverage: cov, totalElements: total, loweredElements: loweredEl,
                           demote: nil, elementFallbacks: fallbacks,
                           unsupportedModifiers: unsupMods, customViews: customVws)
    }

    // DEMOTED — determine the PRIMARY blocking reason, in production priority order.
    var bucket: DemoteBucket
    var engineReason: String

    // The dominant element-level fallback reason (used to refine the bucket + pick a
    // snippet). Tie-break by reason string so the choice is DETERMINISTIC — a Swift
    // Dictionary has no stable order, so a view with two equally-frequent fallback
    // reasons would otherwise bucket differently run-to-run.
    let dominant = fallbacks.sorted(by: {
        $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key
    }).first?.key

    if lowered.referencesUnmarshalledInput {
        // Hardest/earliest blocker — the view is EXCLUDED outright by the pipeline.
        bucket = .unmarshalledInput
        engineReason = "referencesUnmarshalledInput (reads a struct/enum/dict/custom value the guest can't reconstruct)"
        if let d = dominant { engineReason += "  [also: \(d)]" }
    } else if lowered.hasUndispatchableAction {
        bucket = .other
        engineReason = "undispatchable Button action in an alert/toolbar/menu/contextMenu (would be a dead control) → demotes native"
    } else if lowered.hasUndispatchableEffect {
        bucket = .other
        engineReason = "undispatchable effect (.task/.onChange/etc. with a real closure the renderer can't reproduce) → demotes native"
    } else if !(report.hasPatchableLoweredElement || !lowered.indexedRowSlots.isEmpty
                || !lowered.actionSlots.isEmpty || !lowered.effectSlots.isEmpty || !lowered.callbackSlots.isEmpty) {
        bucket = .pureRouter
        engineReason = "no patchable lowered element (pure router/passthrough — no content node, container, modifier, or slot)"
    } else {
        // Not thunkSafe because of a NON-SLOTABLE opaque leaf. The *reason* the leaf
        // is opaque is the dominant element fallback — re-bucket to that so the
        // ranking reflects the real cause (design-system token vs custom child view
        // vs unsupported modifier), not just "non-slotable leaf".
        switch dominant {
        case .some(let r) where r.contains("custom/unsupported view type"):
            bucket = .customChildView; engineReason = r
        case .some(let r) where r.contains("unsupported modifier"):
            // A token in a supported modifier reports as a modifier fallback when the
            // ARGUMENT isn't lowerable. Distinguish design-system tokens from genuinely
            // unsupported modifiers by the snippet shape.
            let snp = snippet(for: report, reasonHint: "modifier", in: source, viewName: lowered.viewName)
            if looksLikeDesignSystemToken(snippet: snp) {
                bucket = .designSystemToken; engineReason = r + "  →  custom design-system token"
            } else {
                bucket = .unsupportedModifier; engineReason = r
            }
        case .some(let r) where r.contains("non-view member") || r.contains("non-inlineable view value"):
            bucket = .computedMember; engineReason = r
        case .some(let r) where r.contains("leading-dot"):
            bucket = .leadingDot; engineReason = r
        case .some(let r) where r.contains("non-constructor") || r.contains("member"):
            let snp = snippet(for: report, reasonHint: "member", in: source, viewName: lowered.viewName)
            if looksLikeDesignSystemToken(snippet: snp) {
                bucket = .designSystemToken; engineReason = r + "  →  custom design-system token"
            } else {
                bucket = .leadingDot; engineReason = r
            }
        case .some(let r):
            bucket = .other; engineReason = r
        case .none:
            // No element fallback but still not thunkSafe — pin the non-slotable leaf.
            if let leaf = lowered.opaqueLeaves.first(where: { !$0.slotable }) {
                bucket = .nonSlotableLeaf
                engineReason = "non-slotable opaque leaf: \(oneLine(leaf.label, max: 80))"
            } else {
                bucket = .other; engineReason = "not thunkSafe (no element fallback recorded)"
            }
        }
    }

    // Pick the snippet. For a non-slotable leaf the most informative snippet is the
    // leaf's own source (one-lined); otherwise drive off the report elements.
    let snip: String
    if bucket == .nonSlotableLeaf, let leaf = lowered.opaqueLeaves.first(where: { !$0.slotable }) {
        snip = oneLine(leaf.source)
    } else {
        snip = snippet(for: report, reasonHint: engineReason, in: source, viewName: lowered.viewName)
    }
    let rec = DemoteRecord(app: app, view: lowered.viewName, file: file.path,
                           bucket: bucket, engineReason: engineReason, snippet: snip)
    return ViewVerdict(app: app, view: lowered.viewName, file: file.path, lowered: false,
                       elementCoverage: cov, totalElements: total, loweredElements: loweredEl,
                       demote: rec, elementFallbacks: fallbacks,
                       unsupportedModifiers: unsupMods, customViews: customVws)
}

// MARK: - Per-app census

extension AppResult {
    var totalViews: Int { verdicts.count }
    var loweredViews: Int { verdicts.filter { $0.lowered }.count }
    var coverage: Double { totalViews == 0 ? 0 : Double(loweredViews) / Double(totalViews) }
    var totalEl: Int { verdicts.reduce(0) { $0 + $1.totalElements } }
    var loweredEl: Int { verdicts.reduce(0) { $0 + $1.loweredElements } }
    var elemCoverage: Double { totalEl == 0 ? 0 : Double(loweredEl) / Double(totalEl) }
}

/// The actual census of ONE app — runs in the WORKER subprocess. A `fatalError`
/// thrown by the engine here will SIGTRAP this process; the orchestrator catches
/// that via the non-zero exit and marks the app crashed.
func censusApp(name: String, root: URL) -> AppResult {
    var result = AppResult(app: name, path: root.path)
    let lowering = BodyLowering()
    let files = developerSwiftFiles(in: root)
    // Read ALL developer sources once, then build the PROJECT-WIDE cross-file bundle so the
    // census mirrors PRODUCTION (`patchcli build` runs the cross-file TWO-PASS via
    // `crossFileBundle(sources:)`). Without this the census was PER-FILE and UNDER-COUNTED: a
    // view that marshals / host-projects a type declared in ANOTHER file (a model in Models/, a
    // view-model in Services/ — the dominant real-app pattern) wrongly demoted here while
    // production lowered it. Build the bundle from ALL sources (incl. non-View Model/Service
    // files), then lower only View-bearing files WITH that bundle.
    var fileSources: [(URL, String)] = []
    for file in files {
        guard let source = try? String(contentsOf: file, encoding: .utf8) else {
            result.unreadable += 1
            continue
        }
        fileSources.append((file, source))
    }
    let crossFile = BodyLowering.crossFileBundle(sources: fileSources.map(\.1))
    for (file, source) in fileSources {
        guard source.contains("View") else { continue }
        result.fileCount += 1
        // lowerAllViews handles parse failures gracefully (returns [] on no views);
        // SwiftParser is error-recovering so a malformed file yields a partial tree.
        let lowereds = lowering.lowerAllViews(source: source, crossFile: crossFile)
        for lv in lowereds {
            result.verdicts.append(verdict(for: lv, app: name, file: file, source: source))
        }
    }
    return result
}

// MARK: - Reporting

func pct(_ d: Double) -> String { String(format: "%.0f%%", d * 100) }
func pct1(_ d: Double) -> String { String(format: "%.1f%%", d * 100) }

// MARK: - Worker mode (census ONE app, emit JSON)

/// `--worker <dir>`: census exactly one app and print its `AppResult` as JSON to
/// stdout. Isolated in its own process so an engine `fatalError` (SIGTRAP — not
/// catchable in-process) only kills THIS worker; the orchestrator notices the
/// non-zero exit and marks the app crashed. Always exits 0 on success.
func runWorker(dir: String) -> Never {
    let url = URL(fileURLWithPath: dir)
    let name = url.lastPathComponent
    let result = censusApp(name: name, root: url)   // may SIGTRAP — that's the point
    let enc = JSONEncoder()
    if let data = try? enc.encode(result) {
        FileHandle.standardOutput.write(data)
    }
    exit(0)
}

// MARK: - Main / orchestrator

let rawArgs = CommandLine.arguments

// Worker dispatch first (no other flags matter in worker mode).
if let wi = rawArgs.firstIndex(of: "--worker"), wi + 1 < rawArgs.count {
    runWorker(dir: rawArgs[wi + 1])
}

var appDirs: [String] = []
var markdown = false
var maxExamplesPerReason = 3
var inProcess = false   // --in-process: census directly (no per-app subprocess), for debugging
var perViewHash = false // --per-view-hash: emit `app<TAB>view<TAB>lowered<TAB>FNV` per view (INERTNESS verifier)
var blockingReads = false // --blocking-reads: dump per DEMOTED view its blocking reads (lever targeting)
var wasmCompile = false // --wasm-compile: emit each app's LOWERED views to a guest module + compile to WASM

var i = 1
while i < rawArgs.count {
    let a = rawArgs[i]
    switch a {
    case "--markdown", "--md":
        markdown = true
    case "--in-process":
        inProcess = true
    case "--per-view-hash":
        perViewHash = true
    case "--blocking-reads":
        blockingReads = true
    case "--wasm-compile":
        wasmCompile = true
    case "--manifest":
        i += 1
        if i < rawArgs.count, let txt = try? String(contentsOfFile: rawArgs[i], encoding: .utf8) {
            for line in txt.components(separatedBy: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.isEmpty || t.hasPrefix("#") { continue }
                appDirs.append((t as NSString).expandingTildeInPath)
            }
        }
    case "--examples":
        i += 1
        if i < rawArgs.count, let n = Int(rawArgs[i]) { maxExamplesPerReason = n }
    default:
        appDirs.append((a as NSString).expandingTildeInPath)
    }
    i += 1
}

guard !appDirs.isEmpty else {
    FileHandle.standardError.write(Data("""
    usage: swiftui-coverage [--markdown] [--examples N] <app-dir> [<app-dir> ...]
           swiftui-coverage [--markdown] --manifest <file-of-dirs>
           swiftui-coverage --worker <app-dir>      # internal: census one app -> JSON
    Each <app-dir> is censused for `: View` lowering (developer source only).
    By default each app runs in its OWN subprocess so an engine crash on one app
    doesn't abort the corpus (the crash is noted). --in-process disables that.
    \n
    """.utf8))
    exit(2)
}

// MARK: - Inertness verifier (`--per-view-hash`)
//
// Emits one line per view: `app<TAB>view<TAB>{0|1 lowered}<TAB>{FNV-1a hash}`. The
// hash covers the FULL lowered emission (guestBody + every slot/token/input/state
// field), so a byte-level diff of two runs (e.g. `main` vs a coverage branch)
// proves INERTNESS: a view that LOWERS on both MUST hash identically (the coverage
// change didn't alter how an already-lowering view ships — the invariant a coverage
// fix must hold). A demote→lower flip is the intended gain; a lower→demote flip or a
// same-status hash change is a REGRESSION. FNV-1a (not Swift's randomized hashValue)
// so the hash is STABLE across processes; `String(describing:)` is comparable across
// the two builds because the hashed struct definitions are untouched by the change.
if perViewHash {
    func fnv1a(_ s: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01b3 }
        return String(h, radix: 16)
    }
    let lowering = BodyLowering()
    var out = ""
    for dir in appDirs {
        let url = URL(fileURLWithPath: dir)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
        let app = url.lastPathComponent
        var fileSources: [(URL, String)] = []
        for f in developerSwiftFiles(in: url) {
            if let s = try? String(contentsOf: f, encoding: .utf8) { fileSources.append((f, s)) }
        }
        let crossFile = BodyLowering.crossFileBundle(sources: fileSources.map(\.1))
        for (_, source) in fileSources {
            guard source.contains("View") else { continue }
            for lv in lowering.lowerAllViews(source: source, crossFile: crossFile) {
                // Mirror the PRODUCTION verdict (verdict(for:) / BuildPipeline.runSwiftUILowering) EXACTLY.
                let thunkSafe = lv.opaqueLeaves.allSatisfy { $0.slotable }
                    && (lv.report.hasPatchableLoweredElement || !lv.indexedRowSlots.isEmpty
                        || !lv.actionSlots.isEmpty || !lv.effectSlots.isEmpty || !lv.callbackSlots.isEmpty)
                    && !lv.hasUndispatchableAction
                    && !lv.hasUndispatchableEffect
                let isLowered = !lv.referencesUnmarshalledInput && !lv.referencesUnresolvedSymbol && thunkSafe
                let canon = lv.guestBody
                    + "|L|" + String(describing: lv.opaqueLeaves)
                    + "|T|" + String(describing: lv.hostTokens)
                    + "|R|" + String(describing: lv.indexedRowSlots)
                    + "|A|" + String(describing: lv.actionSlots)
                    + "|E|" + String(describing: lv.effectSlots)
                    + "|I|" + String(describing: lv.inputs)
                    + "|S|" + String(describing: lv.stateModel)
                out += "\(app)\t\(lv.viewName)\t\(isLowered ? 1 : 0)\t\(fnv1a(canon))\n"
            }
        }
    }
    FileHandle.standardOutput.write(Data(out.utf8))
    exit(0)
}

// MARK: - Blocking-read dump (`--blocking-reads`) — lever targeting
//
// For each DEMOTED view, emit `app<TAB>view<TAB>category<TAB>blockingReads<TAB>swiftDataBlockers`.
// `category` = unmarshalledInput / unresolvedSymbol / undispatchable / other. The blocking-read
// NAMES are the demote diagnostic (`LoweredView.blockingReadNames`) — the exact members/inputs whose
// non-reconstructable value forces the view native. Aggregating these across the corpus tells us which
// SINGLE host-projection lever (enum-comparison / computed-Color / view-model-field / @Model) is the
// SOLE-or-dominant blocker on the most views = the highest-yield lever to build next.
if blockingReads {
    let lowering = BodyLowering()
    var out = ""
    for dir in appDirs {
        let url = URL(fileURLWithPath: dir)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
        let app = url.lastPathComponent
        var fileSources: [(URL, String)] = []
        for f in developerSwiftFiles(in: url) {
            if let s = try? String(contentsOf: f, encoding: .utf8) { fileSources.append((f, s)) }
        }
        let crossFile = BodyLowering.crossFileBundle(sources: fileSources.map(\.1))
        for (_, source) in fileSources {
            guard source.contains("View") else { continue }
            for lv in lowering.lowerAllViews(source: source, crossFile: crossFile) {
                let thunkSafe = lv.opaqueLeaves.allSatisfy { $0.slotable }
                    && (lv.report.hasPatchableLoweredElement || !lv.indexedRowSlots.isEmpty
                        || !lv.actionSlots.isEmpty || !lv.effectSlots.isEmpty || !lv.callbackSlots.isEmpty)
                    && !lv.hasUndispatchableAction && !lv.hasUndispatchableEffect
                let isLowered = !lv.referencesUnmarshalledInput && !lv.referencesUnresolvedSymbol && thunkSafe
                if isLowered { continue }   // only DEMOTED views
                let category: String
                if lv.referencesUnmarshalledInput { category = "unmarshalledInput" }
                else if lv.referencesUnresolvedSymbol { category = "unresolvedSymbol" }
                else if lv.hasUndispatchableAction || lv.hasUndispatchableEffect { category = "undispatchable" }
                else { category = "other" }
                let blocking = lv.blockingReadNames.joined(separator: ",")
                let sdb = lv.swiftDataBlockers.joined(separator: ",")
                out += "\(app)\t\(lv.viewName)\t\(category)\t\(blocking)\t\(sdb)\n"
            }
        }
    }
    FileHandle.standardOutput.write(Data(out.utf8))
    exit(0)
}

// MARK: - WASM-compile robustness (`--wasm-compile`)
//
// For each app: lower every view, take the ones the PRODUCTION verdict marks LOWERED, emit them to a
// single guest module (the same SwiftUIGuestEmitter the build pipeline uses), and actually COMPILE that
// module to WebAssembly. A lowered view whose guest module fails to compile is a REAL engine bug (the
// "lowered-but-doesn't-compile" class — e.g. the cli 1.6.18 effect-slot regression: views reported as
// lowered that silently failed the guest→WASM compile and demoted the whole module). Emits one line per
// app: `app<TAB>{COMPILE_OK|COMPILE_FAIL|NO_VIEWS|SKIP}<TAB>loweredViews<TAB>firstError`.
if wasmCompile {
    let compiler = SwiftWasmCompiler(exportedSymbols: ["view_body", "dispatch", "patch_malloc", "patch_free"])
    guard compiler.toolchainAvailable else {
        FileHandle.standardError.write(Data("WASM toolchain unavailable — --wasm-compile needs swiftly + the WASM SDK on PATH\n".utf8))
        exit(3)
    }
    let lowering = BodyLowering()
    var out = ""
    for dir in appDirs {
        let url = URL(fileURLWithPath: dir)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
        let app = url.lastPathComponent
        var fileSources: [(URL, String)] = []
        for f in developerSwiftFiles(in: url) {
            if let s = try? String(contentsOf: f, encoding: .utf8) { fileSources.append((f, s)) }
        }
        let crossFile = BodyLowering.crossFileBundle(sources: fileSources.map(\.1))
        var loweredViews: [BodyLowering.LoweredView] = []
        for (_, source) in fileSources {
            guard source.contains("View") else { continue }
            for lv in lowering.lowerAllViews(source: source, crossFile: crossFile) {
                let thunkSafe = lv.opaqueLeaves.allSatisfy { $0.slotable }
                    && (lv.report.hasPatchableLoweredElement || !lv.indexedRowSlots.isEmpty
                        || !lv.actionSlots.isEmpty || !lv.effectSlots.isEmpty || !lv.callbackSlots.isEmpty)
                    && !lv.hasUndispatchableAction && !lv.hasUndispatchableEffect
                if !lv.referencesUnmarshalledInput && !lv.referencesUnresolvedSymbol && thunkSafe { loweredViews.append(lv) }
            }
        }
        guard !loweredViews.isEmpty else { out += "\(app)\tNO_VIEWS\t0\t\n"; continue }
        // De-dup by view name (one guest export per type; a duplicate name would clash in the module).
        var seenNames = Set<String>(); var uniq: [BodyLowering.LoweredView] = []
        for lv in loweredViews where seenNames.insert(lv.viewName).inserted { uniq.append(lv) }
        // Mirror BuildPipeline's GuestView construction EXACTLY (a partial init drops the host
        // tokens / geometry / slot args the guest body references → false compile errors like
        // `cannot find '__strtok_…'`/`__geo_width`). Pass thunkSafe + usesGeometry + inputTokens
        // (the input-JSON host tokens) + slotArgs so the emitted guest declares every reserved input.
        let guestViews: [SwiftUIGuestEmitter.GuestView] = uniq.map { lv in
            var slotArgs: [String: [String]] = [:]
            for leaf in lv.opaqueLeaves where !leaf.stringArgs.isEmpty { slotArgs[leaf.id] = leaf.stringArgs }
            return SwiftUIGuestEmitter.GuestView(
                viewName: lv.viewName, guestBody: lv.guestBody, inputs: lv.inputs,
                stateModel: lv.stateModel, thunkSafe: true, usesGeometry: lv.usesGeometry,
                inputTokens: lv.hostTokens.filter { $0.ridesInputJSON }, slotArgs: slotArgs)
        }
        do {
            let emission = try SwiftUIGuestEmitter().emit(views: guestViews)
            let keepArtifacts = ProcessInfo.processInfo.environment["WASMC_KEEP"] != nil
            let tmp = keepArtifacts
                ? URL(fileURLWithPath: "/tmp/wasmc-keep").appendingPathComponent(app)
                : FileManager.default.temporaryDirectory.appendingPathComponent("wasmc-\(app)-\(abs(app.hashValue))")
            try? FileManager.default.removeItem(at: tmp)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { if !keepArtifacts { try? FileManager.default.removeItem(at: tmp) } }
            var sources: [URL] = []
            for fdesc in emission.files {
                let u = tmp.appendingPathComponent(fdesc.fileName)
                try fdesc.contents.write(to: u, atomically: true, encoding: .utf8)
                sources.append(u)
            }
            let outMod = tmp.appendingPathComponent("module.swiftui.wasm")
            let result = try compiler.compile(sources: sources, outputModule: outMod)
            if result.isSuccess {
                out += "\(app)\tCOMPILE_OK\t\(uniq.count)\t\n"
            } else {
                let err = result.log.components(separatedBy: "\n").first(where: { $0.contains("error:") })
                    ?? result.log.components(separatedBy: "\n").last(where: { !$0.isEmpty }) ?? "(no error line)"
                out += "\(app)\tCOMPILE_FAIL\t\(uniq.count)\t\(oneLine(err, max: 200))\n"
            }
        } catch {
            out += "\(app)\tSKIP\t\(uniq.count)\temit/compile threw: \(oneLine("\(error)", max: 160))\n"
        }
        FileHandle.standardOutput.write(Data(out.utf8)); out = ""   // flush per app (long-running)
    }
    exit(0)
}

let selfExe = URL(fileURLWithPath: rawArgs[0]).path

/// Run one app in a child process (`--worker`), returning its decoded result —
/// or a crash record if the worker died (non-zero exit / SIGTRAP from a fatalError).
func censusAppIsolated(name: String, dir: String) -> AppResult {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: selfExe)
    proc.arguments = ["--worker", dir]
    let out = Pipe(); let err = Pipe()
    proc.standardOutput = out
    proc.standardError = err
    do {
        try proc.run()
    } catch {
        return AppResult(app: name, path: dir, crashed: "could not spawn worker: \(error)")
    }
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    if proc.terminationStatus == 0,
       let r = try? JSONDecoder().decode(AppResult.self, from: outData) {
        return r
    }
    // Worker crashed — surface the fatal message (last meaningful stderr line).
    let errStr = String(data: errData, encoding: .utf8) ?? ""
    let fatal = errStr.components(separatedBy: "\n")
        .last(where: { $0.lowercased().contains("fatal error") || $0.lowercased().contains("error:") })
        ?? errStr.components(separatedBy: "\n").last(where: { !$0.isEmpty })
        ?? "exited with status \(proc.terminationStatus)"
    let sig = proc.terminationStatus
    return AppResult(app: name, path: dir,
                     crashed: "worker exit \(sig): \(fatal.trimmingCharacters(in: .whitespaces))")
}

// Run the census over every app dir that exists.
var censuses: [AppResult] = []
var missing: [String] = []
for dir in appDirs {
    let url = URL(fileURLWithPath: dir)
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
        missing.append(dir)
        continue
    }
    let name = url.lastPathComponent
    if inProcess {
        censuses.append(censusApp(name: name, root: url))
    } else {
        censuses.append(censusAppIsolated(name: name, dir: url.path))
    }
}

// Partition: crashed apps are UNMEASURED (reported separately, excluded from the
// coverage math — they're not "0%", we just couldn't measure them).
let crashed = censuses.filter { $0.crashed != nil }.sorted { $0.app < $1.app }
let measured = censuses.filter { $0.crashed == nil }

// Sort: apps WITH views first (by coverage asc — worst first, the interesting ones), then empties.
let withViews = measured.filter { $0.totalViews > 0 }.sorted {
    if $0.coverage != $1.coverage { return $0.coverage < $1.coverage }
    return $0.app < $1.app
}
let withoutViews = measured.filter { $0.totalViews == 0 }.sorted { $0.app < $1.app }

// Aggregate (measured apps only).
let allVerdicts = measured.flatMap { $0.verdicts }
let totalViews = allVerdicts.count
let totalLowered = allVerdicts.filter { $0.lowered }.count
let overallCoverage = totalViews == 0 ? 0 : Double(totalLowered) / Double(totalViews)

// View-level DEMOTE histogram (the primary ranked list).
var demoteHist: [DemoteBucket: [DemoteRecord]] = [:]
for v in allVerdicts {
    if let d = v.demote { demoteHist[d.bucket, default: []].append(d) }
}
// Stable order: count desc, then bucket name (so ties don't reorder run-to-run).
let rankedDemotes = demoteHist.sorted {
    $0.value.count != $1.value.count ? $0.value.count > $1.value.count
                                     : $0.key.rawValue < $1.key.rawValue
}

// Element-level fallback histogram (the finer-grained "why" — surfaces tokens, etc.).
var elemHist: [String: Int] = [:]
for v in allVerdicts {
    for (k, n) in v.elementFallbacks { elemHist[k, default: 0] += n }
}
let rankedElem = elemHist.sorted {
    $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key
}

// The EXACT top unsupported-modifier names + custom-view names across the corpus —
// the most actionable signal for the gap list (which specific things to add next).
// Counted per-VIEW (a view that uses `.resizable()` 3× counts once for it) so the
// ranking reflects "how many views this blocks".
var modBlockedViews: [String: Int] = [:]
var viewBlockedViews: [String: Int] = [:]
for v in allVerdicts where !v.lowered {
    for m in Set(v.unsupportedModifiers) { modBlockedViews[m, default: 0] += 1 }
    for cv in Set(v.customViews) { viewBlockedViews[cv, default: 0] += 1 }
}
let rankedMods = modBlockedViews.sorted {
    $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key
}
let rankedCustomViews = viewBlockedViews.sorted {
    $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key
}

// Element-level coverage aggregate (secondary metric).
let totalElems = allVerdicts.reduce(0) { $0 + $1.totalElements }
let totalElemsLowered = allVerdicts.reduce(0) { $0 + $1.loweredElements }
let elemCoverage = totalElems == 0 ? 0 : Double(totalElemsLowered) / Double(totalElems)

// ---------------------------------------------------------------------------
// EMIT
// ---------------------------------------------------------------------------

if markdown {
    print("## SwiftUI corpus coverage — baseline\n")
    print("**Headline: \(totalLowered)/\(totalViews) views auto-route OTA = \(pct1(overallCoverage)) view-level coverage** across \(measured.count) measured apps" + (crashed.isEmpty ? "." : " (+\(crashed.count) app(s) crashed the engine — see below)."))
    print("\nSecondary (element-level): \(totalElemsLowered)/\(totalElems) body elements lower = \(pct1(elemCoverage)) WASM.\n")
    print("> A view *LOWERS* iff the engine would auto-route it OTA — it is emitted, `thunkSafe`")
    print("> (every opaque leaf slotable + ≥1 lowered content node), and does not read an")
    print("> unmarshalled input. Otherwise it *DEMOTES* to native (renders, but no OTA patch reaches it).")
    print("> The census skips dependency checkouts, build/derived output, Pods, tests, and Patch's")
    print("> own generated thunk/IR files — it measures DEVELOPER source only.\n")

    print("### Per-app coverage\n")
    print("| App | Views lowered | Coverage | Element coverage |")
    print("|---|---|---|---|")
    for c in withViews {
        print("| `\(c.app)` | \(c.loweredViews)/\(c.totalViews) | \(pct(c.coverage)) | \(pct(c.elemCoverage)) |")
    }
    for c in withoutViews {
        print("| `\(c.app)` | — (no `: View` structs) | — | — |")
    }
    for c in crashed {
        print("| `\(c.app)` | ⚠ crashed (unmeasured) | — | — |")
    }
    print("")
    if !crashed.isEmpty {
        print("### ⚠ Apps that CRASHED the engine's lowering (unmeasured — a real engine bug)\n")
        print("These are NOT counted in the coverage above. Each is a `fatalError` thrown by the")
        print("engine on real source — a bug worth fixing (the census isolates each app in a")
        print("subprocess so one crash doesn't abort the corpus):\n")
        for c in crashed {
            print("- `\(c.app)` — \(c.crashed ?? "")")
        }
        print("")
    }

    print("### Ranked DEMOTE reasons (view-level, why a whole view falls back to native)\n")
    print("| Rank | Reason | Views | Share of demotes |")
    print("|---|---|---|---|")
    let totalDemotes = allVerdicts.filter { !$0.lowered }.count
    for (idx, entry) in rankedDemotes.enumerated() {
        let share = totalDemotes == 0 ? 0 : Double(entry.value.count) / Double(totalDemotes)
        print("| \(idx + 1) | \(entry.key.rawValue) | \(entry.value.count) | \(pct(share)) |")
    }
    print("")
    print("### Demote examples (per reason)\n")
    for entry in rankedDemotes {
        print("**\(entry.key.rawValue)** — \(entry.value.count) views\n")
        for rec in entry.value.prefix(maxExamplesPerReason) {
            let snip = rec.snippet.isEmpty ? "(snippet n/a)" : rec.snippet
            print("- `\(rec.app):\(rec.view)` — engine: _\(rec.engineReason)_")
            print("  ```swift")
            print("  \(snip)")
            print("  ```")
        }
        print("")
    }

    print("### Element-level fallback reasons (finer-grained, the exact engine strings)\n")
    print("| Reason (engine string) | Count |")
    print("|---|---|")
    for (k, n) in rankedElem { print("| `\(k)` | \(n) |") }
    print("")

    print("### Top UNSUPPORTED MODIFIERS (by # of demoted views they appear in)\n")
    print("The exact modifiers to add next, highest-impact first:\n")
    print("| Modifier | Demoted views |")
    print("|---|---|")
    for (m, n) in rankedMods.prefix(25) { print("| `.\(m)` | \(n) |") }
    print("")

    print("### Top CUSTOM CHILD VIEWS referenced in bodies (by # of demoted views)\n")
    print("Custom subviews the engine treats as opaque (these are mostly the dev's OWN")
    print("views — once a view's own body lowers + the thunk is wired, a parent that")
    print("references it can slot it; the long tail is app-specific):\n")
    print("| Custom view | Demoted views |")
    print("|---|---|")
    for (cv, n) in rankedCustomViews.prefix(25) { print("| `\(cv)` | \(n) |") }
    print("")
} else {
    // Plain text (default — for terminal / CI logs).
    print("================================================================")
    print(" SwiftUI CORPUS COVERAGE")
    print("================================================================")
    print("Apps measured: \(measured.count)" + (crashed.isEmpty ? "" : "   (+\(crashed.count) crashed)") + "   Views found: \(totalViews)")
    print("")
    print("HEADLINE (view-level, OTA auto-route): \(totalLowered)/\(totalViews) = \(pct1(overallCoverage))")
    print("Element-level coverage:                \(totalElemsLowered)/\(totalElems) = \(pct1(elemCoverage))")
    print("")
    print("---- per-app coverage (worst first) ----")
    for c in withViews {
        print(String(format: "  %-34@ %3d/%-3d (%@)",
                     c.app as NSString, c.loweredViews, c.totalViews, pct(c.coverage) as NSString))
        if c.unreadable > 0 {
            print("      ! \(c.unreadable) file(s) unreadable")
        }
    }
    for c in withoutViews {
        print(String(format: "  %-34@   — (no : View structs)", c.app as NSString))
    }
    for c in crashed {
        print(String(format: "  %-34@   ! CRASHED (unmeasured)", c.app as NSString))
    }
    print("")
    if !crashed.isEmpty {
        print("---- ⚠ apps that CRASHED the engine lowering (unmeasured) ----")
        for c in crashed { print("  ! \(c.app): \(c.crashed ?? "")") }
        print("")
    }
    print("---- ranked DEMOTE reasons (view-level) ----")
    let totalDemotes = allVerdicts.filter { !$0.lowered }.count
    for (idx, entry) in rankedDemotes.enumerated() {
        let share = totalDemotes == 0 ? 0 : Double(entry.value.count) / Double(totalDemotes)
        print(String(format: "  %2d. [%3d, %@]  %@", idx + 1, entry.value.count,
                     pct(share) as NSString, entry.key.rawValue as NSString))
        for rec in entry.value.prefix(maxExamplesPerReason) {
            print("        e.g. \(rec.app):\(rec.view)")
            if !rec.snippet.isEmpty { print("             \(rec.snippet)") }
        }
    }
    print("")
    print("---- element-level fallback reasons (engine strings) ----")
    for (k, n) in rankedElem {
        print(String(format: "  %4d  %@", n, k as NSString))
    }
    print("")
    print("---- top UNSUPPORTED MODIFIERS (by # demoted views) ----")
    for (m, n) in rankedMods.prefix(20) {
        print(String(format: "  %4d  .%@", n, m as NSString))
    }
    print("")
    print("---- top CUSTOM CHILD VIEWS in bodies (by # demoted views) ----")
    for (cv, n) in rankedCustomViews.prefix(20) {
        print(String(format: "  %4d  %@", n, cv as NSString))
    }
    print("")
    if !missing.isEmpty {
        print("---- MISSING app dirs (skipped) ----")
        for m in missing { print("  ! \(m)") }
        print("")
    }
}

// Always emit the headline to stderr too, so a one-liner can grep it.
FileHandle.standardError.write(Data(
    "CORPUS-COVERAGE headline: \(totalLowered)/\(totalViews) views lower OTA = \(pct1(overallCoverage))\n".utf8))
