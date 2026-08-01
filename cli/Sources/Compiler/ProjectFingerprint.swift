// SPDX-License-Identifier: Apache-2.0

import Foundation
import PartitioningEngine
import CodeGenerator

/// Builds a `FingerprintComponents` snapshot from a real project directory, then
/// hands it to `Fingerprinter` for the SHA-256 (per the plan's "Fingerprint
/// Components"). This is the native-shell fingerprint: a change to ANY component
/// here is OTA-incompatible and requires an App Store submission.
///
/// Each component is gathered deterministically (sorted file lists, content
/// hashes for file bodies so a moved-but-identical file still matches). The WASM
/// module binary and WASM-compiled `_wasm.swift` sources are intentionally
/// excluded — those are exactly what OTA updates are allowed to change.
public struct ProjectFingerprinter {
    public let sdkVersion: String
    public let wasmKitVersion: String
    public let swiftCompilerVersion: String
    /// The native registry used to classify OTA-eligibility when normalizing the
    /// native-shell fingerprint ([BUG-2]). Defaults to the standard registry — the
    /// same one `BuildPipeline` uses — so the fingerprint's notion of "OTA-eligible"
    /// matches what the build actually ships OTA.
    public let registry: NativeRegistry

    public init(
        sdkVersion: String = ProjectFingerprinter.defaultSDKVersion,
        wasmKitVersion: String = ProjectFingerprinter.defaultWasmKitVersion,
        swiftCompilerVersion: String = ProjectFingerprinter.detectSwiftVersion(),
        registry: NativeRegistry = .standard
    ) {
        self.sdkVersion = sdkVersion
        self.wasmKitVersion = wasmKitVersion
        self.swiftCompilerVersion = swiftCompilerVersion
        self.registry = registry
    }

    public static let defaultSDKVersion = "0.1.0"
    public static let defaultWasmKitVersion = "0.1.5"

    /// Best-effort detection of the host Swift compiler version string.
    public static func detectSwiftVersion() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift", "--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if let s = String(data: data, encoding: .utf8) {
                // First line, collapsed — e.g. "Apple Swift version 6.3.2 (...)".
                let first = s.split(separator: "\n").first.map(String.init) ?? s
                return normalizeSwiftVersion(first.trimmingCharacters(in: .whitespaces))
            }
        } catch {}
        return "unknown"
    }

    /// [BUG #41] Reduce a raw `swift --version` first line to JUST its semantic
    /// version number (e.g. `6.3.2`), discarding the vendor prefix and the parenthetical
    /// build/commit suffix. The SAME Swift release reports DIFFERENT first lines depending
    /// on which toolchain is first on `PATH`:
    ///   • the Apple/Xcode toolchain → "Apple Swift version 6.1.2 (swiftlang-6.1.2.x...)"
    ///   • the swift.org/swiftly toolchain → "Swift version 6.1.2 (swift-6.1.2-RELEASE)"
    /// Because the WASM-compile shell puts swiftly first on PATH while the host-build shell
    /// puts /usr/bin first (see CONTRIBUTING.md), registering the fingerprint in one shell and
    /// pushing in the other flipped `swiftCompilerVersion` and tripped a spurious MISMATCH
    /// on an otherwise-identical machine. Keying on the bare `MAJOR.MINOR[.PATCH]` makes the
    /// component PATH-order-independent while STILL churning on a real compiler-version bump
    /// (which is the only swift-version change that affects how a module is built/run). If no
    /// dotted version is found we fall back to the trimmed original (never weaker than before).
    static func normalizeSwiftVersion(_ line: String) -> String {
        // Match the first `N.N` or `N.N.N` token in the line (the release version).
        if let r = line.range(of: #"[0-9]+\.[0-9]+(\.[0-9]+)?"#, options: .regularExpression) {
            return "swift " + String(line[r])
        }
        return line
    }

    /// A breakdown returned alongside the components, so `fingerprint diff` can
    /// show *which* category changed without re-deriving anything.
    public struct Snapshot: Sendable {
        public let components: FingerprintComponents
        public let fingerprint: String
        /// Per-component hash, keyed by a stable category label (for diffing).
        public let componentHashes: [(label: String, hash: String)]
    }

    /// [BUG #19 / #42] Whether the build will LOWER SwiftUI/UIKit view bodies for THIS
    /// run — the single gate that decides whether a view/cell body actually ships OTA. It
    /// MUST match `BuildPipeline`'s `swiftUIOn`: an explicit `PATCH_SWIFTUI` env var wins
    /// (=0 off, anything else on), else the `.Patch.yml swiftui:` setting passed by the
    /// caller (`buildSwiftUI`, default on). When this is FALSE the build produces ZERO
    /// lowered view modules — every `var body` / cell `configure` renders from the SIGNED
    /// native binary — so their bodies are NATIVE SHELL and MUST stay hashed verbatim
    /// (stripping them would let a real native view-body edit slip the compatibility gate:
    /// a FALSE-STABLE). With it TRUE we behave exactly as before.
    static func swiftUILoweringOn(configBuildSwiftUI: Bool) -> Bool {
        if let env = ProcessInfo.processInfo.environment["PATCH_SWIFTUI"] {
            return env != "0"
        }
        return configBuildSwiftUI
    }

    /// Compute a fingerprint snapshot over a project directory.
    ///
    /// - Parameters:
    ///   - projectDir: directory to scan for native swift files / Info.plist / etc.
    ///   - bridges: enabled bridge names from `.Patch.yml` (a bridge def change
    ///     alters the native shell, so it is fingerprinted).
    ///   - deploymentTarget: e.g. "iOS 17.0" (best-effort from project).
    ///   - linkedFrameworks: frameworks the shell links (best-effort).
    ///   - buildSwiftUI: the `.Patch.yml swiftui:` setting (default on). When the build
    ///     does NOT lower SwiftUI/UIKit bodies (this is `false`, OR `PATCH_SWIFTUI=0`),
    ///     view/cell bodies render NATIVE and are kept hashed — so a real native view-body
    ///     edit still trips the gate ([BUG #19 / #42]). Callers should pass `config.buildSwiftUI`.
    public func snapshot(
        projectDir: URL,
        bridges: [String: Bool],
        excludes: [String] = [],
        deploymentTarget: String? = nil,
        linkedFrameworks: [String]? = nil,
        buildSwiftUI: Bool = true
    ) -> Snapshot {
        let fm = FileManager.default
        // Does the build lower view bodies for this run? Gates the SwiftUI + UIKit body
        // strips below; when off, those bodies are native shell and stay hashed verbatim.
        let swiftUIOn = Self.swiftUILoweringOn(configBuildSwiftUI: buildSwiftUI)

        // [R2-#9/#10/#11/#34/#35/#36] The build→fingerprint hand-off. A prior
        // `build`/`push`/`release` wrote the AUTHORITATIVE set of view/cell/function
        // bodies it ACTUALLY shipped OTA. When present we strip ONLY bodies in that set —
        // a body the build dropped to native (the guest-compile bisect / convergence
        // reclassified it, or a whole-file/whole-module decline) stays hashed verbatim, so
        // a real native-shell edit to it churns and forces the native update the device
        // truly needs (NEVER a FALSE-STABLE). Absent (no successful build yet, e.g. a fresh
        // `register`) → the strip set falls back to the STATIC prediction, the pre-fix
        // behavior (no worse than before; the gate is exercised by push/release, which
        // always carry a fresh manifest). `push`/`release` compute this snapshot AFTER the
        // build, so the gate they enforce uses the build-confirmed truth.
        let shippedManifest = ShippedOTAManifest.read(projectDir: projectDir)

        // [BUG-2] The fingerprint gates NATIVE-SHELL (deployed-binary) compatibility,
        // NOT the OTA-patchable code. Hashing every `.swift` file's RAW content made
        // an edit to an OTA-eligible function body (exactly what OTA exists to ship)
        // change the fingerprint → a spurious "FINGERPRINT MISMATCH" that forced
        // `--force` on the product's core happy path. The fix: hash each native file
        // with the BODIES of OTA-eligible functions NEUTRALIZED, so a body-only edit
        // to patchable code leaves the fingerprint stable, while a genuine
        // native-shell change still trips it:
        //   - editing a `native`/non-eligible function (its body is kept verbatim),
        //   - changing a function SIGNATURE (the signature line is kept verbatim, and
        //     the eligible-function set is keyed by qualified id+signature),
        //   - adding/removing/renaming a function or file, or any non-`.swift`
        //     shell input (Info.plist/entitlements/frameworks/bridges/target).
        // We run the partitioning engine ONCE over the project to learn which
        // functions are OTA-eligible (wasmEligible/bridged/mixed) and their line
        // spans, then strip only those bodies before hashing. If analysis fails we
        // fall back to hashing raw content (never weaker than the old behavior).
        //
        // [R2-#10] FALSE-STABLE: a `.wasmEligible` function the static analyzer labels
        // OTA-eligible can FAIL the actual WASM compile and be reclassified native by the
        // convergence loop (or a CORE support failure can demote ALL candidates at once),
        // so its body renders NATIVE on device. Stripping it then made a real native edit
        // to it produce no churn. We strip wasmEligible bodies ONLY when the build's
        // manifest confirms the general module compiled CLEAN (no demotions / CORE
        // failure). When the manifest says general logic is UNTRUSTED, we hash every
        // wasmEligible body verbatim (the fingerprint can't cheaply tell which function
        // dropped — the functionID↔export map is lost in the emitter — so it's
        // over-conservative, never false-stable). Absent a manifest (no build yet), keep
        // the historical static strip (the gate is enforced by push/release, which always
        // carry a fresh, clean-or-untrusted manifest).
        let generalStripAllowed = shippedManifest?.generalLogicTrusted ?? true
        var eligibleSpansByFile = generalStripAllowed
            ? Self.otaEligibleBodySpans(projectDir: projectDir, registry: registry)
            : [:]

        // [BUG: view-body false-positive] The partitioning engine FORCES every
        // SwiftUI `var body` to NATIVE (it's a view-DSL member), so a view body is
        // never `.wasmEligible` and the strip set above NEVER contains it — every
        // view-body edit churned the fingerprint and `push`/`release` HARD-REFUSED
        // the OTA push. That is a FALSE POSITIVE on the product's headline workflow
        // (edit a view, ship OTA). But a view body IS OTA-shippable when the SwiftUI
        // lowering pipeline lowers it PURELY (rides WASM through the thunk, with NO
        // native slot closures baked into the binary). We consult that pipeline
        // (read-only) and ADD the body spans of PURELY-OTA-lowered views to the
        // strip set — so a restyle/reorder/add-feature edit to such a body keeps the
        // fingerprint STABLE, the SAME way an OTA-eligible function body already does.
        //
        // SAFETY (no false negatives): a span is added ONLY for a view that lowers
        // with ZERO native slots (`opaqueLeaves.isEmpty`) AND is not excluded
        // (renders natively) AND lowers ≥1 real content node (the build's own
        // auto-route precondition). A MIXED view (native slot closures compiled into
        // the SIGNED binary) is NOT stripped — editing a slotted span changes native
        // code the patch can't carry, a real native-shell change, so it stays hashed
        // and still trips the gate. When in doubt we strip LESS. See
        // `loweredViewBodySpans` for the full soundness argument.
        // AUTO-ROUTED VIEWS: strip the body span of every view the build AUTO-ROUTES
        // (thunkSafe — including a MIXED view whose every opaque leaf is slotable), because
        // its lowered content rides WASM (OTA-patchable) — so editing a constant/literal/
        // structure there must NOT churn the native-shell fingerprint (the #1 P0: a pure
        // `Text("…")`/`spacing:` edit in an auto-routed mixed view was wrongly refused).
        // The body's ONLY native residue — the thunk's slot/token/row-slot closures — is
        // folded back into the file hash via `nativeSurface` (so a slot/token edit STILL
        // churns). A view that does NOT auto-route renders native → NOT stripped → churns.
        //
        // [BUG #19 / #42] GATED on `swiftUIOn`: when the build does NOT lower SwiftUI
        // (swiftui:false / PATCH_SWIFTUI=0) it ships ZERO lowered view modules, so every
        // `var body` renders from the SIGNED native binary — its body is native shell and
        // MUST stay hashed. Stripping it then (as before this fix) made a real native
        // view-body edit produce NO churn → the gate falsely reported COMPATIBLE.
        var nativeSurfaceByFile: [String: String] = [:]
        var slotLiteralRanges: [String: [Range<Int>]] = [:]
        if swiftUIOn {
            // [R2-#9/#34/#35/#36] Strip a view body ONLY if the build SHIPPED it OTA
            // (`shippedManifest.shippedSwiftUIViews`). A view the static `isAutoRouted`
            // gate predicted shippable but the build's guest-compile bisect / convergence
            // dropped to native (or a whole-module decline shipped ZERO views) must stay
            // hashed — else a body edit to it looks OTA-benign but never reaches the device
            // (FALSE-STABLE). nil (no build yet) → keep the static prediction (push/release
            // always pass a fresh manifest, so the enforced gate uses the build truth).
            let autoRouted = Self.loweredAutoRoutedViewData(
                projectDir: projectDir, registry: registry,
                shippedViews: shippedManifest.map { Set($0.shippedSwiftUIViews) })
            for (file, spans) in autoRouted.bodySpansByFile {
                eligibleSpansByFile[file, default: []].append(contentsOf: spans)
            }
            nativeSurfaceByFile = autoRouted.nativeSurfaceByFile

            // PARAMETERIZED NATIVE SLOTS: per-file byte ranges of the string literals the
            // SwiftUI lowering LIFTED out of a slotted custom-view call (they ride WASM via
            // `slotArgs`, the slot factory is literal-independent). Editing one is OTA, so
            // the walker normalizes exactly those bytes to a placeholder — a string edit to
            // a slotted custom view (`DisplayText(text: "Settings")`) keeps the fingerprint
            // stable, while a non-string edit to the same slot still trips the gate. This is
            // surgical (only the lifted literals), unlike the whole-body span strip above.
            slotLiteralRanges = Self.loweredParameterizedSlotLiteralRanges(
                projectDir: projectDir, registry: registry,
                shippedViews: shippedManifest.map { Set($0.shippedSwiftUIViews) })

            // [BUG #20] LOWERED UIKit CELLS: the engine ALSO lowers a declarative cell
            // `configure(with:)` / `setupViews()` to a guest module the build ships
            // (`runUIKitLowering`), so editing such a body is a genuine OTA change — but the
            // method is a UIKit-DSL member FORCED NATIVE by the partitioning engine, never
            // `.wasmEligible`, and there was no UIKit analogue of the SwiftUI strip. So a
            // benign OTA cell edit (a label text / spacing change) churned `native swift
            // files` and the push was HARD-REFUSED. Strip the lowered construction-method
            // body span exactly like an auto-routed `var body`, folding the cell's native
            // surface (`customSlots`/`hostTokens`/`actionIDs`/effects) back into the hash so
            // a slot/action/effect edit STILL churns. Gated on `swiftUIOn` (UIKit lowering
            // rides the same `swiftui` toggle in the build).
            // [R2-#11] Strip a UIKit cell body ONLY if the build SHIPPED it. The UIKit
            // path converges ONCE with NO per-cell bisect — if cell B fails to compile the
            // whole wrapper demotes and `runUIKitLowering` returns nil → ZERO cells ship.
            // So a statically-lowerable cell can render native; its body must stay hashed.
            let uikit = Self.loweredUIKitCellData(
                projectDir: projectDir, registry: registry,
                shippedCells: shippedManifest.map { Set($0.shippedUIKitCells) })
            for (file, spans) in uikit.bodySpansByFile {
                eligibleSpansByFile[file, default: []].append(contentsOf: spans)
            }
            for (file, surf) in uikit.nativeSurfaceByFile {
                if let existing = nativeSurfaceByFile[file] {
                    nativeSurfaceByFile[file] = existing + "\u{1}" + surf
                } else {
                    nativeSurfaceByFile[file] = surf
                }
            }
        }

        // --- native swift files: every .swift EXCEPT generated _wasm.swift ---
        // We hash each file's (shell-normalized) content so a content-identical file
        // at a new path still produces the same per-file token (path|contentHash).
        var nativeFiles: [String] = []
        var generatedStubs: [String] = []
        // [BUG-3] The native-shell fingerprint must hash ONLY the developer's own
        // native sources — exactly the set the partitioning engine treats as the
        // shell. The previous walk applied only `.skipsHiddenFiles` + user `excludes`,
        // so for any app whose SwiftPM dependencies are checked out IN-TREE (Xcode's
        // `build/SourcePackages/checkouts/…`, `DerivedData/…`, CocoaPods, Carthage)
        // it hashed THOUSANDS of transitive-dependency sources into the fingerprint.
        // Real-world impact (a real production app): 1,888 files hashed for a 34-file app — so
        // the fingerprint churned on every `swift package` re-resolve / rebuild and
        // the OTA-compatibility gate was permanently "MISMATCH". Apply the SAME
        // exclusion the parser/discovery walks use (`SwiftParserEngine`) so the
        // fingerprint can never again diverge from the engine's notion of the native
        // shell, and PRUNE whole artifact subtrees (`skipDescendants`) so we never
        // even traverse the (potentially gigabytes of) dependency/DerivedData clones.
        // Test sources are excluded too — they compile into a SEPARATE test target,
        // never the shipped app binary, so editing a test can't change OTA compat.
        for f in shellFiles(in: projectDir, fm: fm) where f.pathExtension == "swift" {
            if SwiftParserEngine.isTestFile(f) { continue }
            let rel = relativePath(f, base: projectDir)
            if excludes.contains(where: { Self.excludeMatches($0, relativePath: rel, fileName: f.lastPathComponent) }) { continue }
            let name = f.lastPathComponent
            if name.hasSuffix("_wasm.swift") {
                // OTA-updatable — NOT part of the native fingerprint.
                continue
            } else if name == ThunkGenerator.thunkFileName
                        || name == UIKitThunkGenerator.thunkFileName {
                // The dedicated generated-folder thunk file (HYBRID placement) is
                // `patchcli prepare`'s OWN regenerated output — NOT the developer's native
                // shell. It is wholly recreated on every prepare (and absent before the
                // first one), so hashing it would make the fingerprint vary with prepare
                // and resurrect the P0 false-MISMATCH. Skip it exactly like `_wasm.swift`.
                // (The same-file factored helper block in a developer file is separately
                // stripped by `stripPatchScaffolding` so THAT file's hash stays invariant.)
                // [R2-#13] The UIKit analogue (`PatchUIKitThunks.generated.swift`,
                // written by `Prepare.prepareUIKitCells` into a cell file's directory) is
                // the SAME kind of regenerated scaffolding — exclude it too, or registering
                // a fingerprint BEFORE prepare then auto-preparing on the next release
                // would see a brand-new native .swift file and falsely MISMATCH.
                continue
            } else if name.hasSuffix("_bridge.swift") {
                // Generated native-shell stub: hashed verbatim (it IS shell).
                generatedStubs.append("\(rel)|\(contentHash(f))")
            } else {
                // Hash the shell-normalized body (OTA-eligible bodies stripped, and
                // lifted parameterized-slot string literals normalized to a placeholder).
                let hash = Self.shellNormalizedHash(
                    of: f, eligibleSpans: eligibleSpansByFile[f.standardizedFileURL.path],
                    slotLiteralRanges: slotLiteralRanges[f.standardizedFileURL.path],
                    nativeSurfaceSuffix: nativeSurfaceByFile[f.standardizedFileURL.path])
                nativeFiles.append("\(rel)|\(hash)")
            }
        }
        nativeFiles.sort()
        generatedStubs.sort()

        // --- bridge definitions: enabled bridges, sorted ---
        let bridgeDefs = bridges.filter { $0.value }.keys.sorted().map { "\($0).bridge" }

        // --- Info.plist / entitlements: hash their contents if present ---
        let infoPlist = firstFileHash(in: projectDir, named: "Info.plist", fm: fm)
        let entitlements = firstFileMatchingHash(in: projectDir, ext: "entitlements", fm: fm)

        // --- linked frameworks: explicit, else inferred from imports ---
        let frameworks = (linkedFrameworks ?? inferFrameworks(in: projectDir, fm: fm)).sorted()

        // --- deployment target ---
        let target = deploymentTarget ?? inferDeploymentTarget(in: projectDir, fm: fm) ?? "iOS 17.0"

        let components = FingerprintComponents(
            sdkVersion: sdkVersion,
            wasmKitVersion: wasmKitVersion,
            bridgeDefinitions: bridgeDefs,
            nativeSwiftFiles: nativeFiles,
            nativeGeneratedStubs: generatedStubs,
            infoPlist: infoPlist,
            entitlements: entitlements,
            linkedFrameworks: frameworks,
            deploymentTarget: target,
            swiftCompilerVersion: swiftCompilerVersion
        )

        let labeled: [(String, String)] = [
            ("SDK version", Fingerprinter.hash(components.sdkVersion)),
            ("WasmKit version", Fingerprinter.hash(components.wasmKitVersion)),
            ("bridge definitions", Fingerprinter.hash(components.bridgeDefinitions.joined(separator: "|"))),
            ("native swift files", Fingerprinter.hash(components.nativeSwiftFiles.joined(separator: "|"))),
            ("native generated stubs", Fingerprinter.hash(components.nativeGeneratedStubs.joined(separator: "|"))),
            ("Info.plist", Fingerprinter.hash(components.infoPlist)),
            ("entitlements", Fingerprinter.hash(components.entitlements)),
            ("linked frameworks", Fingerprinter.hash(components.linkedFrameworks.joined(separator: "|"))),
            ("deployment target", Fingerprinter.hash(components.deploymentTarget)),
            ("swift compiler version", Fingerprinter.hash(components.swiftCompilerVersion)),
        ]

        return Snapshot(
            components: components,
            fingerprint: Fingerprinter.fingerprint(components),
            componentHashes: labeled
        )
    }

    /// A JSON-serializable components dictionary for the backend
    /// `POST /fingerprints` `components` field (audit / diff trail).
    public static func componentsDictionary(_ s: Snapshot) -> [String: Any] {
        let c = s.components
        return [
            "sdkVersion": c.sdkVersion,
            "wasmKitVersion": c.wasmKitVersion,
            "bridgeDefinitions": c.bridgeDefinitions,
            "nativeSwiftFileCount": c.nativeSwiftFiles.count,
            "nativeGeneratedStubCount": c.nativeGeneratedStubs.count,
            // The per-file "relpath|hash" lists are stored so a later mismatch can
            // name EXACTLY which native files changed (not just "native files
            // changed"). They are sorted + content-hashed, so they carry no source.
            "nativeSwiftFiles": c.nativeSwiftFiles,
            "nativeGeneratedStubs": c.nativeGeneratedStubs,
            "linkedFrameworks": c.linkedFrameworks,
            "deploymentTarget": c.deploymentTarget,
            "swiftCompilerVersion": c.swiftCompilerVersion,
            "componentHashes": Dictionary(uniqueKeysWithValues: s.componentHashes.map { ($0.label, $0.hash) }),
        ]
    }

    // MARK: - Mismatch explanation (which components/files changed)

    /// Compare a freshly-computed local `Snapshot` against the backend's stored
    /// components and return human-readable lines naming WHAT changed in the native
    /// shell — so a `FINGERPRINT MISMATCH` tells the developer exactly which
    /// component (and, for native sources, which files) is the culprit instead of
    /// just printing two opaque hashes.
    ///
    /// Returns `[]` when no per-component data is available to diff against (an old
    /// backend record with no `componentHashes`); the caller then falls back to the
    /// generic "run `patchcli fingerprint diff`" guidance. Each returned line is
    /// pre-indented for direct printing under a "What changed:" header.
    public static func changedComponents(
        local: Snapshot, backend: StoredFingerprintComponents?
    ) -> [String] {
        guard let backend, let backendHashes = backend.componentHashes else { return [] }
        var lines: [String] = []

        // Walk the UNION of local AND backend per-category hashes; a category whose
        // hashes differ (or that is present on only one side — CLI/backend version
        // skew) is one that changed. [BUG] Iterating only `local.componentHashes` made
        // a backend-only label (a key the current CLI no longer emits) invisible. Sort
        // the union for a stable, human-sensible ordering. (`local.componentHashes` is
        // an array of (label, hash) tuples; index it by label.) The per-category
        // wording lives in the shared `changedComponentLines` helper.
        let localByLabel = Dictionary(local.componentHashes.map { ($0.label, $0.hash) },
                                      uniquingKeysWith: { a, _ in a })
        let labels = Set(localByLabel.keys).union(backendHashes.keys).sorted()
        for label in labels {
            guard backendHashes[label] != localByLabel[label] else { continue }  // unchanged
            let detail = changedComponentLines(forLabel: label, local: local, backend: backend)
            lines += detail.isEmpty
                ? ["  • \(label) changed (present in only one of local/backend — version skew)"]
                : detail
        }
        return lines
    }

    // MARK: - Component-level classification (partial-patch safety)

    /// How a single changed native-shell component relates to the OTA patch the
    /// developer is about to ship.
    ///
    /// SAFETY MODEL — the whole point of the fingerprint is to refuse an OTA module
    /// that is incompatible with the SIGNED binary on devices. A "partial patch"
    /// (ship the view patch even though the native shell drifted) is sound ONLY when
    /// the native delta provably CANNOT affect the shipped patch. We err hard toward
    /// `patchAffecting`: a component is `nativeOnly` ONLY if a change to it is, by
    /// construction, invisible to the WASM module + its ABI. When in doubt, it is
    /// patch-affecting and the skip is NOT offered.
    public enum DeltaKind: String, Sendable, Equatable {
        /// The change is to a NATIVE-SHELL-ONLY input that the OTA module never reads,
        /// links against, or depends on for its ABI — so the patch built before the
        /// change is still valid against the new shell. Safe to offer skip-and-patch.
        case nativeOnly
        /// The change CAN affect the OTA module (its source, its ABI, its runtime).
        /// NEVER offer the skip — shipping the patch would risk a stale/incompatible
        /// module on the new binary.
        case patchAffecting
    }

    /// One changed component, classified, with the human-readable diff lines that
    /// `changedComponents` already produces for it.
    public struct ComponentDelta: Sendable, Equatable {
        public let label: String        // the stable category label (componentHashes key)
        public let kind: DeltaKind
        public let detailLines: [String] // pre-indented lines (same as changedComponents)
        public init(label: String, kind: DeltaKind, detailLines: [String]) {
            self.label = label; self.kind = kind; self.detailLines = detailLines
        }
    }

    /// The result of classifying ALL changed components against a backend baseline.
    public struct DeltaReport: Sendable, Equatable {
        public let deltas: [ComponentDelta]
        public init(deltas: [ComponentDelta]) { self.deltas = deltas }
        /// True when there IS a mismatch AND every changed component is `nativeOnly`
        /// — i.e. the native shell drifted but only in ways the OTA patch can't see.
        /// This is the SOLE condition under which skip-and-patch may be offered.
        public var changed: Bool { !deltas.isEmpty }
        public var allNativeOnly: Bool {
            !deltas.isEmpty && deltas.allSatisfy { $0.kind == .nativeOnly }
        }
        public var hasPatchAffecting: Bool {
            deltas.contains { $0.kind == .patchAffecting }
        }
        public var nativeOnly: [ComponentDelta] { deltas.filter { $0.kind == .nativeOnly } }
        public var patchAffecting: [ComponentDelta] { deltas.filter { $0.kind == .patchAffecting } }
    }

    /// Classify a component label as `nativeOnly` (the OTA patch can't see a change
    /// to it) or `patchAffecting` (a change CAN reach the shipped patch).
    ///
    /// The `nativeOnly` set is deliberately narrow and each entry carries its own
    /// soundness argument:
    ///
    ///   • `Info.plist`  — pure native-shell metadata (display name, permission
    ///     strings, URL schemes, background modes). The WASM module neither reads nor
    ///     links against Info.plist; it is consumed only by the native binary / iOS at
    ///     launch. A patch built before the change is byte-for-byte valid after it.
    ///   • `entitlements` — native binary capabilities (keychain groups, App Groups,
    ///     push). Same argument: the signed binary's entitlements are an OS/codesign
    ///     concern the WASM ABI is blind to.
    ///   • `linked frameworks` — ADDING/removing a framework the shell links is the
    ///     canonical "I added a native package but my views are unaffected" case. This
    ///     is sound ONLY in combination: if a patched view had STARTED using the new
    ///     framework, the view's Swift SOURCE would have changed too and would show up
    ///     under `native swift files` (which IS patch-affecting), blocking the skip.
    ///     So a framework delta alone — with native swift files unchanged — means the
    ///     source the patch was compiled from is identical to the binary's; safe.
    ///   • `deployment target` — the minimum iOS version is a native BUILD setting. It
    ///     changes which OS versions the signed binary supports, not the JSON-marshalled
    ///     WASM ABI (which is OS-version-independent). Raising/lowering it can't make a
    ///     patch built against unchanged source incompatible with the running binary.
    ///
    /// Everything else is `patchAffecting`:
    ///   • `native swift files` — THE critical one. Even with OTA-eligible bodies
    ///     normalized out (BUG-2), a hit here means a NATIVE function, a signature, a
    ///     file add/remove, or a generated stub changed — any of which can change the
    ///     surface the patch is built against. We cannot soundly prove, from the
    ///     fingerprint alone, that such a change is invisible to the specific views the
    ///     patch ships, so we never skip on it.
    ///   • `bridge definitions` — host bridges are capabilities the WASM module CALLS.
    ///     Removing one a patch relies on would crash it; even an addition shifts the
    ///     shell ABI surface. Patch-affecting.
    ///   • `SDK version` / `WasmKit version` / `swift compiler version` — these govern
    ///     how the module is marshalled and executed on-device. A version skew can
    ///     change the runtime contract, so a patch must be rebuilt + re-registered.
    static func classifyDelta(label: String) -> DeltaKind {
        switch label {
        case "Info.plist", "entitlements", "linked frameworks", "deployment target":
            return .nativeOnly
        default:
            // native swift files, native generated stubs, bridge definitions,
            // SDK/WasmKit/swift-compiler versions, and any unknown future label.
            return .patchAffecting
        }
    }

    /// Compute the per-component delta report between a freshly-computed local
    /// `Snapshot` and the backend's stored components, classifying each changed
    /// component as native-only vs patch-affecting. Reuses `changedComponents`'
    /// human-readable diff lines so the detail is identical to what a mismatch prints.
    ///
    /// Returns an empty-`deltas` report when there's nothing to diff against (an old
    /// backend record with no `componentHashes`) — the caller then treats it as "no
    /// component detail available", never as "safe to skip".
    public static func componentDeltas(
        local: Snapshot, backend: StoredFingerprintComponents?
    ) -> DeltaReport {
        guard let backend, let backendHashes = backend.componentHashes else {
            return DeltaReport(deltas: [])
        }
        var deltas: [ComponentDelta] = []
        // [BUG] Iterate the UNION of local AND backend label sets. Iterating only
        // `local.componentHashes` makes a backend-only label INVISIBLE: a backend record
        // carrying a `componentHashes` key the current CLI no longer emits (CLI/backend
        // version skew) yields no delta, so if every locally-visible changed label is
        // native-only, `allNativeOnly` would be true and PushFlow would offer the skip
        // despite an unclassified backend-only component — contradicting the "when in
        // doubt, refuse" model. A label present on exactly one side is an unclassifiable
        // structural change: emit a delta for it (its kind defaults to `patchAffecting`
        // via `classifyDelta` for any unknown label), forcing `allNativeOnly` to false.
        // (`local.componentHashes` is an array of (label, hash) tuples; index it by label.)
        let localByLabel = Dictionary(local.componentHashes.map { ($0.label, $0.hash) },
                                      uniquingKeysWith: { a, _ in a })
        let labels = Set(localByLabel.keys).union(backendHashes.keys)
        for label in labels {
            let localHash = localByLabel[label]
            let backendHash = backendHashes[label]
            guard backendHash != localHash else { continue }  // unchanged
            // Reuse the exact detail lines `changedComponents` emits for this single
            // category, so the breakdown reads identically to the mismatch output. A
            // label absent on one side may have no source-of-truth wording — fall back
            // to a generic line so the delta is never silently empty.
            var detail = changedComponentLines(forLabel: label, local: local, backend: backend)
            if detail.isEmpty {
                detail = ["  • \(label) changed (present in only one of local/backend — version skew)"]
            }
            deltas.append(ComponentDelta(label: label,
                                         kind: classifyDelta(label: label),
                                         detailLines: detail))
        }
        // Stable, human-sensible order: native-only first, then patch-affecting,
        // each group alphabetized by label.
        deltas.sort { a, b in
            if a.kind != b.kind { return a.kind == .nativeOnly }
            return a.label < b.label
        }
        return DeltaReport(deltas: deltas)
    }

    /// The detail lines for ONE changed category — factored out of `changedComponents`
    /// so both the flat list and the classified `componentDeltas` share one source of
    /// truth for the per-category wording.
    static func changedComponentLines(
        forLabel label: String, local: Snapshot, backend: StoredFingerprintComponents
    ) -> [String] {
        switch label {
        case "native swift files":
            return fileDiffLines(
                title: "Native source files",
                backendEntries: backend.nativeSwiftFiles,
                localEntries: local.components.nativeSwiftFiles,
                backendCount: backend.nativeSwiftFileCount,
                localCount: local.components.nativeSwiftFiles.count)
        case "native generated stubs":
            return fileDiffLines(
                title: "Generated native stubs",
                backendEntries: backend.nativeGeneratedStubs,
                localEntries: local.components.nativeGeneratedStubs,
                backendCount: backend.nativeGeneratedStubCount,
                localCount: local.components.nativeGeneratedStubs.count)
        case "bridge definitions":
            return listDiffLines(title: "Host bridges",
                                 backend: backend.bridgeDefinitions,
                                 local: local.components.bridgeDefinitions)
        case "linked frameworks":
            return listDiffLines(title: "Linked frameworks",
                                 backend: backend.linkedFrameworks,
                                 local: local.components.linkedFrameworks)
        case "deployment target":
            return [scalarLine("Deployment target",
                               from: backend.deploymentTarget,
                               to: local.components.deploymentTarget)]
        case "swift compiler version":
            return [scalarLine("Swift compiler",
                               from: backend.swiftCompilerVersion,
                               to: local.components.swiftCompilerVersion)]
        case "SDK version":
            return [scalarLine("PatchSDK version",
                               from: backend.sdkVersion,
                               to: local.components.sdkVersion)]
        case "WasmKit version":
            return [scalarLine("WasmKit version",
                               from: backend.wasmKitVersion,
                               to: local.components.wasmKitVersion)]
        case "Info.plist":
            return ["  • Info.plist changed"]
        case "entitlements":
            return ["  • Entitlements changed"]
        default:
            return ["  • \(label) changed"]
        }
    }

    /// Human title for a component label — the header shown before its detail lines
    /// in `fingerprint diff` and the push-flow's native-drift summary.
    public static func titleForLabel(_ label: String) -> String {
        switch label {
        case "native swift files": return "Native source files"
        case "native generated stubs": return "Generated native stubs"
        case "bridge definitions": return "Host bridges"
        case "linked frameworks": return "Linked frameworks"
        case "deployment target": return "Deployment target"
        case "swift compiler version": return "Swift compiler"
        case "SDK version": return "PatchSDK version"
        case "WasmKit version": return "WasmKit version"
        case "Info.plist": return "Info.plist"
        case "entitlements": return "Entitlements"
        default: return label
        }
    }

    /// "label: old → new" for a single scalar component.
    private static func scalarLine(_ label: String, from old: String?, to new: String?) -> String {
        let o = (old?.isEmpty == false) ? old! : "—"
        let n = (new?.isEmpty == false) ? new! : "—"
        return "  • \(label): \(o) → \(n)"
    }

    /// Added/removed entries for a list component (bridges, frameworks).
    private static func listDiffLines(title: String, backend: [String]?, local: [String]) -> [String] {
        let before = Set(backend ?? [])
        let after = Set(local)
        let added = after.subtracting(before).sorted()
        let removed = before.subtracting(after).sorted()
        if backend == nil && added.isEmpty && removed.isEmpty {
            return ["  • \(title) changed"]
        }
        var parts: [String] = []
        if !added.isEmpty { parts.append("added " + added.joined(separator: ", ")) }
        if !removed.isEmpty { parts.append("removed " + removed.joined(separator: ", ")) }
        return parts.isEmpty ? ["  • \(title) changed"] : ["  • \(title): " + parts.joined(separator: "; ")]
    }

    /// Per-file added/removed/modified lines from the "relpath|hash" entry lists.
    /// When the backend record predates per-file storage (`backendEntries == nil`),
    /// fall back to a count-level summary and tell the user how to get file detail.
    private static func fileDiffLines(
        title: String, backendEntries: [String]?, localEntries: [String],
        backendCount: Int?, localCount: Int
    ) -> [String] {
        func parse(_ entries: [String]) -> [String: String] {
            var m: [String: String] = [:]
            for e in entries {
                // Format is "relpath|hash"; the hash suffix is hex (no '|'), so split
                // on the LAST separator to be safe against a '|' in a path.
                guard let bar = e.lastIndex(of: "|") else { continue }
                m[String(e[..<bar])] = String(e[e.index(after: bar)...])
            }
            return m
        }

        guard let backendEntries else {
            // Old record: only a count was stored. Be honest about the limit.
            let was = backendCount.map(String.init) ?? "?"
            var line = "  • \(title) changed (\(was) → \(localCount) files)"
            if backendCount == localCount { line = "  • \(title) changed (\(localCount) files — content edited)" }
            return [line,
                    "      re-run `patchcli fingerprint register` to enable per-file detail"]
        }

        let before = parse(backendEntries)
        let after = parse(localEntries)
        let added = after.keys.filter { before[$0] == nil }.sorted()
        let removed = before.keys.filter { after[$0] == nil }.sorted()
        let modified = after.keys.filter { k in before[k] != nil && before[k] != after[k] }.sorted()

        let total = added.count + removed.count + modified.count
        guard total > 0 else { return ["  • \(title) changed"] }

        var lines = ["  • \(title) (\(total) changed):"]
        // Cap the printed list so a huge refactor doesn't flood the terminal.
        let cap = 12
        var shown = 0
        func emit(_ marker: String, _ paths: [String]) {
            for p in paths {
                if shown >= cap { return }
                lines.append("      \(marker) \(p)")
                shown += 1
            }
        }
        emit("~", modified)   // modified
        emit("+", added)      // added
        emit("-", removed)    // removed
        if total > shown { lines.append("      … and \(total - shown) more") }
        return lines
    }

    // MARK: - OTA-eligible body normalization ([BUG-2])

    /// Run the partitioning engine over the project and collect, per native source
    /// file, the line spans of OTA-eligible functions (`wasmEligible`/`bridged`/
    /// `mixed`). Keyed by the standardized file path. Returns an empty map if
    /// analysis fails (the caller then hashes raw content — never weaker than the
    /// pre-fix gate). Generated `_wasm.swift`/test files are already excluded by the
    /// engine's own walker, so they never appear here.
    static func otaEligibleBodySpans(
        projectDir: URL, registry: NativeRegistry
    ) -> [String: [(start: Int, end: Int)]] {
        guard let report = try? PartitioningEngine(registry: registry).analyze(directory: projectDir) else {
            return [:]
        }
        var spans: [String: [(start: Int, end: Int)]] = [:]
        // Only FULLY-PURE (`wasmEligible`) function bodies are exempt: their entire
        // body ships OTA, so a body edit is genuinely OTA-compatible. A `mixed` /
        // `bridged` function keeps NATIVE statements in the deployed shell (only its
        // pure part is lifted), so editing it CAN change the shell — those bodies are
        // hashed verbatim (left in the fingerprint) so such a change still trips the
        // gate. Conservative by construction: when in doubt, the body stays hashed.
        for r in report.results where r.classification == .wasmEligible {
            guard let rec = report.records[r.functionID] else { continue }
            let key = rec.sourceFile.standardizedFileURL.path
            spans[key, default: []].append((start: rec.startLine, end: rec.endLine))
        }
        return spans
    }

    // MARK: - Lowered SwiftUI view-body normalization (view-body false-positive)

    /// Run the SwiftUI lowering pipeline over the project (read-only) and collect,
    /// per native source file, the line span of every `var body` that lowers
    /// PURELY-OTA — i.e. it rides WASM through the auto-patch thunk with NO native
    /// code (slot closures) baked into the signed binary. Editing such a body is
    /// genuinely OTA-shippable (the product's headline workflow), so its span is
    /// added to the fingerprint strip set, exactly like a `wasmEligible` function
    /// body. Keyed by the standardized file path. Returns an empty map if analysis
    /// fails (the caller then leaves view bodies hashed — never weaker than the
    /// pre-fix gate, which hashed them all).
    ///
    /// SAFETY MODEL — zero false negatives. A view body is stripped ONLY when ALL of:
    ///   • `opaqueLeaves.isEmpty` — the view lowers with NO native slots. A MIXED
    ///     view bakes native slot closures into the SIGNED binary (the `.opaque`
    ///     leaves the build-time thunk compiles natively); editing a slotted span
    ///     changes that native code, which the OTA patch CANNOT carry — a real
    ///     native-shell change. So a mixed view is NEVER stripped (it stays hashed
    ///     and trips the gate), exactly as `otaEligibleBodySpans` leaves `mixed`/
    ///     `bridged` function bodies hashed. This is the conservative choice: we
    ///     strip ONLY purely-OTA views, never a partially-native one.
    ///   • `!referencesUnmarshalledInput` && `!referencesUnresolvedSymbol` — the
    ///     build EXCLUDES such a view from guest emission; it renders FULLY NATIVE.
    ///     A native view's body edit is a native change → must stay hashed.
    ///   • `report.hasLoweredContentNode` — the build's own auto-route precondition
    ///     (a pure routing/layout shell is NOT routed, stays native). Matching it
    ///     means we strip ONLY views the build would actually ship OTA.
    ///   • `report.coverage == 1.0` — every classified element rode WASM. Redundant
    ///     with `opaqueLeaves.isEmpty` (a non-lowered element becomes an opaque leaf)
    ///     but kept as a belt-and-suspenders invariant: a 100%-coverage body has, by
    ///     construction, nothing native left in it.
    /// This is STRICTER than the build's `thunkSafe` verdict (which auto-routes a
    /// mixed view whose every opaque leaf is slotable). We deliberately decline to
    /// strip those: their slot closures ARE native. When in doubt, strip LESS.
    ///
    /// The lowering result carries only the view's NAME (not a source file / line
    /// span), so we re-parse with the partitioning engine — which already records
    /// every `var body` as a `FunctionRecord` with `sourceFile`/`startLine`/`endLine`
    /// — and join the purely-OTA view names to their body records by
    /// (sourceFile, enclosing-type-name). A view whose `body` record we can't locate
    /// is simply not stripped (safe).
    /// Both halves of the auto-routed-view fingerprint treatment, computed in one pass:
    ///   • `bodySpansByFile` — the body line spans to STRIP (the lowered content rides
    ///     WASM, so editing it is an OTA change, not a native-shell change).
    ///   • `nativeSurfaceByFile` — the COMPLETE native code the thunk derives from each
    ///     auto-routed body (`__patchSlots()`/`__patchTokens()`/`__patchRowSlots()` =
    ///     `opaqueLeaves` + `hostTokens` + `indexedRowSlots`), folded back into that
    ///     file's hash so a slot/token/row-slot edit STILL churns. This is the complete
    ///     set of body-derived native code (verified against `ThunkGenerator`).
    struct LoweredViewFingerprintData {
        var bodySpansByFile: [String: [(start: Int, end: Int)]] = [:]
        var nativeSurfaceByFile: [String: String] = [:]
    }

    /// SHARED cross-file lowering source set — the canonical list of the developer's own
    /// `.swift` sources the SwiftUI lowering ingests (for the cross-file catalogs AND the
    /// per-file lowering). BOTH the build (`BuildPipeline`) and these fingerprint walks call
    /// THIS one function so their file sets are byte-identical: any divergence makes the
    /// auto-routed-view set the fingerprint strips differ from what the build ships, and a
    /// benign OTA-patchable edit would wrongly churn the native-shell fingerprint (the user's
    /// #1 P0). Excludes exactly the artifacts the native-shell walk does — dependency/build
    /// output (`isBuildArtifactPath`), `.patch`/`.swiftpm`, hidden trees (`.skipsHiddenFiles`),
    /// test files, the generated `*_wasm.swift` guest sources, and `prepare`'s own thunk file.
    /// Returns `(standardized path, source)` pairs SORTED by path so the cross-file bundle is
    /// order-DETERMINISTIC — `FileManager` enumeration order is not guaranteed stable, and an
    /// order-sensitive catalog merge would otherwise make the fingerprint itself non-deterministic.
    /// - Parameter excludes: `.Patch.yml` `exclude:` entries. [R2-#128] When supplied, a file
    ///   matching one is skipped exactly as the native walk + `prepare` do, so the build's
    ///   lowered-view set equals prepare's thunked set (an excluded view neither ships a wasted
    ///   module nor gets stripped). Default `[]` keeps the historical all-files behavior.
    static func crossFileLoweringSources(
        projectDir: URL, excludes: [String] = []
    ) -> [(key: String, source: String)] {
        let fm = FileManager.default
        // [R2-#129] NO `.skipsHiddenFiles` — `prepare`'s `swiftSources` walks hidden trees
        // (it only manually skips `.build`/`.git`/`.patch`/`.swiftpm` + build artifacts), so a
        // view under a leading-dot dir (`.sourcery/Generated/CardView.swift`) gets a thunk
        // from prepare. If THIS walk skipped it (the old `.skipsHiddenFiles`), the build never
        // shipped that view's body → the thunk referenced a missing export → on-device demote.
        // Match prepare exactly: descend hidden dirs but skip the SAME dot-dirs + artifacts.
        guard let enumerator = fm.enumerator(
            at: projectDir,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .canonicalPathKey],
            options: []
        ) else { return [] }
        var fileSources: [(key: String, source: String)] = []
        // [R2-#104] Dedup by RESOLVED path (symlinks collapsed). `FileManager.enumerator`
        // descends directory symlinks and can yield the same physical file under two paths
        // (`Shared -> ../Shared`), double-counting its view export base → the build's
        // collision check would then drop the view as a false same-name collision. Keying on
        // `resolvingSymlinksInPath` (or the canonical path) makes one physical file → one entry.
        var seenResolved = Set<String>()
        for case let f as URL in enumerator {
            let lowerPath = f.path.lowercased()
            let isDir = (try? f.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                let n = f.lastPathComponent
                if n == ".build" || n == ".git" || n == ".patch" || n == ".swiftpm"
                    || SwiftParserEngine.isBuildArtifactPath(lowerPath + "/") {
                    enumerator.skipDescendants()
                }
                continue
            }
            if lowerPath.contains("/.build/") || lowerPath.contains("/.git/")
                || lowerPath.contains("/.patch/") || lowerPath.contains("/.swiftpm/") { continue }
            if SwiftParserEngine.isBuildArtifactPath(lowerPath) { continue }
            guard f.pathExtension == "swift" else { continue }
            if SwiftParserEngine.isTestFile(f) { continue }
            if f.lastPathComponent.hasSuffix("_wasm.swift") { continue }
            if f.lastPathComponent.hasSuffix("_bridge.swift") { continue }   // generated native stub, never a view source
            // [BUG-1] A custom `--output` dir defeats the `/.patch/` location skip above —
            // the engine's generated support family (`_PatchFusionShims`/`_PatchHelper_*`/
            // `_PatchNamespaces`/`_PatchType_*`/`_PatchGenerics`/…) lands outside `.Patch/`
            // and must never be re-ingested as a developer view source. Skip by NAME so the
            // exclusion is location-independent.
            if f.lastPathComponent.hasPrefix("_Patch") { continue }
            if f.lastPathComponent == ThunkGenerator.thunkFileName { continue }   // our generated thunk output
            if f.lastPathComponent == UIKitThunkGenerator.thunkFileName { continue }   // [R2-#13] our generated UIKit thunk output
            // SwiftPM manifests are tooling files (not app sources) — `prepare` skips them too.
            if f.lastPathComponent == "Package.swift" || f.lastPathComponent.hasPrefix("Package@swift-") { continue }
            // [R2-#128] Honor `.Patch.yml` excludes (same matcher as the native walk).
            if !excludes.isEmpty {
                let rel = f.standardizedFileURL.path.hasPrefix(projectDir.standardizedFileURL.path)
                    ? String(f.standardizedFileURL.path.dropFirst(projectDir.standardizedFileURL.path.count))
                        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    : f.lastPathComponent
                if excludes.contains(where: { Self.excludeMatches($0, relativePath: rel, fileName: f.lastPathComponent) }) { continue }
            }
            // [R2-#104] One entry per physical file.
            let resolved = (try? f.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath)
                ?? f.resolvingSymlinksInPath().standardizedFileURL.path
            guard seenResolved.insert(resolved).inserted else { continue }
            guard let source = try? String(contentsOf: f, encoding: .utf8) else { continue }
            fileSources.append((f.standardizedFileURL.path, source))
        }
        return fileSources.sorted { $0.key < $1.key }
    }

    /// SINGLE SOURCE OF TRUTH for the same-file-thunk mode (`PATCH_SAMEFILE_THUNK`, default ON).
    /// The lowering's host-projection of a `private`/`fileprivate` member depends on whether the
    /// thunk lives in the view's own file (can reach privates) or a separate file (cannot) — so a
    /// view reading a private member LOWERS differently per mode. BOTH the build (`BuildPipeline`)
    /// and these fingerprint walks MUST pass the SAME value to `lowerAllViews`, or in the `=0`
    /// opt-out a benign OTA edit to such a view would wrongly churn the native-shell fingerprint
    /// (the user's #1 P0). The fingerprint previously omitted it and silently took the default
    /// `true`, diverging from a `PATCH_SAMEFILE_THUNK=0` build.
    static var sameFileThunkEnabled: Bool {
        ProcessInfo.processInfo.environment["PATCH_SAMEFILE_THUNK"] != "0"
    }

    static func loweredViewBodySpans(
        projectDir: URL, registry: NativeRegistry
    ) -> [String: [(start: Int, end: Int)]] {
        loweredAutoRoutedViewData(projectDir: projectDir, registry: registry).bodySpansByFile
    }

    /// The auto-routed-view fingerprint data (see `LoweredViewFingerprintData`). We strip
    /// the body of every view the build AUTO-ROUTES (`thunkSafe` — a mixed view whose
    /// every opaque leaf is slotable counts, not just a 100%-pure body), because such a
    /// view renders OTA from WASM. SOUNDNESS (no false negative): the body's only native
    /// residue is the thunk's slot/token/row-slot closures, which we hash back via
    /// `nativeSurfaceByFile`. A view that does NOT auto-route (renders its native `body`)
    /// is NOT stripped — its body stays hashed verbatim, so editing it churns (correct).
    /// - Parameter shippedViews: when non-nil (a build manifest was present), the
    ///   AUTHORITATIVE set of view names the build actually shipped OTA — only THESE bodies
    ///   are stripped (a statically-auto-routed view the build dropped to native stays
    ///   hashed, fixing the FALSE-STABLE [R2-#9/#34/#35/#36]). nil → strip the full static
    ///   auto-routed set (pre-build fallback; the enforced gate in push/release passes a
    ///   fresh manifest). The native SURFACE is folded in regardless of shipping status.
    static func loweredAutoRoutedViewData(
        projectDir: URL, registry: NativeRegistry, shippedViews: Set<String>? = nil
    ) -> LoweredViewFingerprintData {
        let lowering = BodyLowering()
        // file path -> [LoweredView] kept for the two-pass (collision detection needs the
        // full cross-file set before we can decide which views auto-route).
        var loweredByFile: [String: [BodyLowering.LoweredView]] = [:]
        var exportBaseCounts: [String: Int] = [:]
        // PASS 0 — the SHARED source set (incl. model-class files that have NO `View` text, so the
        // cross-file catalogs below see the reactive models). Identical, by construction, to the
        // build's lowering source set (`crossFileLoweringSources` is the single source of truth), so
        // the auto-routed set diverges from the build NEVER and a patchable body edit can't wrongly
        // churn the fingerprint.
        let fileSources = Self.crossFileLoweringSources(projectDir: projectDir)
        guard !fileSources.isEmpty else { return LoweredViewFingerprintData() }
        // CROSS-FILE reactive catalogs — built from ALL sources, IDENTICAL to BuildPipeline's, so the
        // auto-routed set the fingerprint strips matches what the build ships (host-projection +
        // reactive-collection cross-file; struct/enum marshalling-input cross-file stays dormant).
        let crossFile = BodyLowering.crossFileBundle(sources: fileSources.map(\.source))
        for (key, source) in fileSources {
            // Cheap pre-filter (matches the build): no `View` text → no view to lower.
            guard source.contains("View") else { continue }
            let lowered = lowering.lowerAllViews(source: source, sameFileThunk: Self.sameFileThunkEnabled, crossFile: crossFile)
            loweredByFile[key] = lowered
            for lv in lowered where lv.report.totalElements > 0 {
                exportBaseCounts[SwiftUIGuestEmitter.exportSymbol(forView: lv.viewName), default: 0] += 1
            }
        }
        // Export bases claimed by 2+ views can't be routed (the SDK routes a live view by
        // its unqualified type name and can't disambiguate) → those views render native.
        let collidingBases = Set(exportBaseCounts.filter { $0.value > 1 }.keys)
        // [R2-#95] Views prepare won't thunk (same-named non-View struct / generic-where).
        let thunkIneligible = BuildPipeline.thunkIneligibleViewNames(sources: fileSources.map(\.source))

        // Per file: the auto-routed view names + their native surface; and the view names
        // that did NOT auto-route (to disambiguate same-named bodies, exactly as before).
        var autoRoutedByFile: [String: Set<String>] = [:]
        var notAutoRoutedByFile: [String: Set<String>] = [:]
        var surfaceFragmentsByFile: [String: [String]] = [:]
        // TEMP DIAGNOSTIC (env-gated, PATCH_EXPLAIN_AUTOROUTE=1): per-view auto-route verdict
        // + the FIRST blocking `isAutoRouted` condition. Reporting-only; never changes output.
        let explainAutoRoute = ProcessInfo.processInfo.environment["PATCH_EXPLAIN_AUTOROUTE"] == "1"
        for (key, lowereds) in loweredByFile {
            for lv in lowereds {
                let base = SwiftUIGuestEmitter.exportSymbol(forView: lv.viewName)
                if Self.isAutoRouted(lv, collidingBases: collidingBases, thunkIneligible: thunkIneligible) {
                    autoRoutedByFile[key, default: []].insert(lv.viewName)
                    surfaceFragmentsByFile[key, default: []].append(Self.nativeSurface(of: lv))
                    _ = base
                    if explainAutoRoute { FileHandle.standardError.write(Data("VIEW \(lv.viewName): AUTOROUTED\n".utf8)) }
                } else {
                    notAutoRoutedByFile[key, default: []].insert(lv.viewName)
                    if explainAutoRoute {
                        let reason = Self.explainAutoRouteBlock(lv, collidingBases: collidingBases, thunkIneligible: thunkIneligible)
                        FileHandle.standardError.write(Data("VIEW \(lv.viewName): BLOCKED \(reason)\n".utf8))
                    }
                }
            }
        }
        guard !autoRoutedByFile.isEmpty else { return LoweredViewFingerprintData() }
        // A name that is BOTH auto-routed and not in one file (two same-named view types)
        // is ambiguous: we can't tell which `body` record is which, so strip NEITHER.
        for (key, notRouted) in notAutoRoutedByFile {
            autoRoutedByFile[key]?.subtract(notRouted)
        }
        // [R2-#9/#34/#35/#36] BUILD-CONFIRMED INTERSECTION: when a build manifest is
        // present, keep ONLY view names the build actually SHIPPED OTA. A view the static
        // auto-route gate predicted shippable but the build dropped to native (bisect /
        // convergence / whole-module decline) is removed here, so its body stays HASHED
        // (an edit to it churns → forces the native update). nil → no manifest → strip the
        // full static set (pre-build fallback). (The native SURFACE collected above is
        // folded in for every auto-routed view regardless: a non-stripped/native view's
        // body is hashed verbatim anyway, so an extra surface fragment is at worst redundant
        // hash input — never a missed churn.)
        if let shippedViews {
            for key in autoRoutedByFile.keys {
                autoRoutedByFile[key] = autoRoutedByFile[key]?.intersection(shippedViews)
            }
        }

        // (2) Join auto-routed view names to their `var body` line spans via the
        // partitioning engine's `.computedProperty` FunctionRecords (sourceFile + lines).
        var data = LoweredViewFingerprintData()
        if let report = try? PartitioningEngine(registry: registry).analyze(directory: projectDir) {
            for rec in report.records.values where rec.kind == .computedProperty {
                let parts = rec.id.split(separator: ".").map(String.init)
                guard parts.count >= 2, parts.last == "body" else { continue }
                let enclosingType = parts[parts.count - 2]
                let key = rec.sourceFile.standardizedFileURL.path
                guard let routed = autoRoutedByFile[key], routed.contains(enclosingType) else { continue }
                data.bodySpansByFile[key, default: []].append((start: rec.startLine, end: rec.endLine))
            }
        }
        // The native surface is hashed regardless of whether we located the body span
        // (a span we can't locate just means that body isn't stripped — strictly safer).
        for (key, frags) in surfaceFragmentsByFile where !frags.isEmpty {
            data.nativeSurfaceByFile[key] = frags.sorted().joined(separator: "\u{1}")
        }
        return data
    }

    /// The build's AUTO-ROUTE (`thunkSafe`) verdict, replicated for the fingerprint: a view
    /// the SDK renders from WASM (so its lowered body is OTA-patchable). Mirrors
    /// `BuildPipeline`'s gate EXACTLY (err toward NOT auto-routed = hash verbatim = safe).
    static func isAutoRouted(_ lv: BodyLowering.LoweredView, collidingBases: Set<String>,
                             thunkIneligible: Set<String> = []) -> Bool {
        // [R2-#95] A view `patchcli prepare` won't thunk (a same-named non-View struct
        // exists, or a generic-`where` view) renders NATIVE on device even though the
        // engine's View-only collision check would ship it. Mirror prepare's eligibility so
        // the fingerprint doesn't strip a body that never auto-routes (a false-stable).
        if thunkIneligible.contains(lv.viewName) { return false }
        if collidingBases.contains(SwiftUIGuestEmitter.exportSymbol(forView: lv.viewName)) { return false }
        if lv.referencesUnmarshalledInput || lv.referencesUnresolvedSymbol { return false }
        guard lv.report.totalElements > 0 else { return false }
        // MUST mirror the build's `thunkSafe` gate EXACTLY (or the fingerprint strips a body
        // the build keeps native, and a patchable edit wrongly churns the native-shell hash):
        // a Button in an alert/toolbar/menu actions list with an undispatchable action demotes
        // the whole view to native there too.
        if lv.hasUndispatchableAction { return false }
        // ... and a view with a dead/destructive behavioral/lifecycle modifier the engine
        // COULDN'T keep native as a `nativeEffectSlot` (a `.onChange`/`.onReceive` state-watcher,
        // an un-slotable / animation-driving effect) demotes to native in the build — mirror it
        // exactly. (A view whose ONLY effect-block reason was a SLOTTABLE effect has
        // `hasUndispatchableEffect == false` + a non-empty `effectSlots`, so it auto-routes below.)
        if lv.hasUndispatchableEffect { return false }
        // thunkSafe: every opaque leaf is slotable AND there's a real lowered content node
        // (or an indexed-row slot, a native-action-slot button, or a native effect slot). A
        // non-slotable leaf, or a pure routing/layout shell, renders native.
        guard lv.opaqueLeaves.allSatisfy({ $0.slotable }) else { return false }
        return lv.report.hasPatchableLoweredElement || !lv.indexedRowSlots.isEmpty
            || !lv.actionSlots.isEmpty || !lv.effectSlots.isEmpty || !lv.callbackSlots.isEmpty
    }

    /// TEMP DIAGNOSTIC (env-gated): the FIRST failing `isAutoRouted` condition for a
    /// non-auto-routed view, in the SAME order `isAutoRouted` evaluates them, with the
    /// blocking detail (unresolved symbols / blocking reads / SwiftData / leaf source).
    /// Reporting-only; never affects what ships.
    static func explainAutoRouteBlock(_ lv: BodyLowering.LoweredView, collidingBases: Set<String>,
                                      thunkIneligible: Set<String> = []) -> String {
        if thunkIneligible.contains(lv.viewName) { return "thunkIneligible (same-named non-View struct / generic-where)" }
        if collidingBases.contains(SwiftUIGuestEmitter.exportSymbol(forView: lv.viewName)) { return "name-collision (export base claimed by 2+ views)" }
        if lv.referencesUnmarshalledInput {
            let detail = lv.blockingReadNames.isEmpty ? "" : " reads=[\(lv.blockingReadNames.joined(separator: ","))]"
            let sd = lv.swiftDataBlockers.isEmpty ? "" : " swiftData=[\(lv.swiftDataBlockers.joined(separator: ","))]"
            return "referencesUnmarshalledInput\(detail)\(sd)"
        }
        if lv.referencesUnresolvedSymbol {
            let detail = lv.unresolvedSymbols.isEmpty ? "" : " symbols=[\(lv.unresolvedSymbols.joined(separator: ","))]"
            return "referencesUnresolvedSymbol\(detail)"
        }
        guard lv.report.totalElements > 0 else { return "no-lowered-elements (totalElements==0)" }
        if lv.hasUndispatchableAction { return "hasUndispatchableAction (Button in alert/toolbar/menu actions list w/ non-dispatchable action)" }
        if lv.hasUndispatchableEffect { return "hasUndispatchableEffect (.task/.onChange/.onDelete/.onMove/non-trivial .onAppear/gesture)" }
        if let leaf = lv.opaqueLeaves.first(where: { !$0.slotable }) {
            let src = leaf.source.replacingOccurrences(of: "\n", with: " ").prefix(80)
            return "non-slotable-leaf (\(src))"
        }
        if !(lv.report.hasPatchableLoweredElement || !lv.indexedRowSlots.isEmpty) {
            return "no-patchable-lowered-element (pure routing/layout shell)"
        }
        return "unknown (auto-routed per gate — should not appear here)"
    }

    /// The COMPLETE native code the thunk derives from an auto-routed view's body —
    /// `__patchSlots()` (`opaqueLeaves`, TEMPLATED so a lifted string arg rides WASM and
    /// does NOT churn), `__patchTokens()` (`hostTokens` — the native expression the thunk
    /// evaluates), `__patchRowSlots()` (`indexedRowSlots`), and `__patchActionSlots()`
    /// (`actionSlots` — the native action closure body the thunk runs over `self`). Hashing
    /// this is what keeps stripping the body sound: a slot/token/row-slot/action-slot edit
    /// changes this string → churns the native-shell hash (a native change → MISMATCH); an edit
    /// to the lowered (WASM) content — incl. a Button LABEL or its `role` — does not.
    /// (Verified complete vs `ThunkGenerator`.)
    static func nativeSurface(of lv: BodyLowering.LoweredView) -> String {
        var parts: [String] = []
        for leaf in lv.opaqueLeaves where leaf.slotable && !leaf.source.isEmpty {
            parts.append("S:\(leaf.id)|\(leaf.source)")
        }
        for tok in lv.hostTokens {
            parts.append("T:\(tok.id)|\(tok.kind.rawValue)|\(tok.source)")
        }
        for row in lv.indexedRowSlots {
            parts.append("R:\(row.id)|\(row.collectionSource)|\(row.loopVar)|\(row.rowSource)")
        }
        // NATIVE-ACTION SLOTS: fold each actions-list Button's action closure SOURCE. Editing the
        // native action (`deleteSubscription(s)` → add a line) churns the hash → MISMATCH (correct:
        // it's a native-shell change the OTA patch can't carry). Editing the Button LABEL/role
        // strips (it rides WASM), so a label edit stays fingerprint-stable + ships OTA.
        for act in lv.actionSlots {
            parts.append("A:\(act.id)|\(act.source)")
        }
        // NATIVE EFFECT-MODIFIER SLOTS: fold each effect modifier's re-application SOURCE. Editing
        // the native effect (`.task { await self.load() }` → change the call) churns the hash →
        // MISMATCH (correct: it's a native-shell change the OTA patch can't carry). Editing the
        // lowered content text inside the modified subtree strips (it rides WASM), so a body text
        // edit stays fingerprint-stable + ships OTA.
        for eff in lv.effectSlots {
            parts.append("E:\(eff.id)|\(eff.applySource)")
        }
        // CHILD-VIEW CALLBACK SLOTS: fold only the SLOT SOURCE (the call with the stable forwarder
        // closure, NOT the original closure body). Editing the callback body is OTA-stable: the slot
        // source stays constant (the forwarder is position-keyed), so `CB:` is unchanged → the
        // fingerprint is stable → the edit ships OTA via WASM dispatch. Editing the NON-closure args
        // (e.g., changing a navigation label) changes the slot source → churns the hash → MISMATCH
        // (correct: the non-closure args are native-compiled and can't be patched without a new thunk).
        for cb in lv.callbackSlots {
            parts.append("CB:\(cb.id)|\(cb.slotSource)")
        }
        return parts.sorted().joined(separator: "\u{2}")
    }

    // MARK: - Lowered UIKit cell-body normalization ([BUG #20])

    /// [BUG #20] Run the UIKit cell lowering (read-only) and collect, per native source
    /// file, the line span of every declarative construction method (`configure(with:)`/
    /// `setupViews()`/…) the build LOWERS + ships (`runUIKitLowering`). Editing such a body
    /// is a genuine OTA change (a label-text / spacing edit — the headline UIKit workflow),
    /// but the method is a UIKit-DSL member FORCED NATIVE by the partitioning engine (never
    /// `.wasmEligible`) and the SwiftUI strip didn't cover it, so the cell body stayed hashed
    /// verbatim → a benign cell edit churned `native swift files` → the push was HARD-REFUSED.
    /// We strip the construction-method body span exactly like an auto-routed `var body`,
    /// folding the cell's native surface back into the hash so a slot/action/effect edit STILL
    /// churns. Keyed by standardized file path. Empty map on analysis failure (then nothing
    /// is stripped — never weaker than the pre-fix gate, which hashed the body).
    ///
    /// SOUNDNESS: we strip ONLY a cell the lowering would actually SHIP — i.e. it does NOT
    /// `referencesUnmarshalledInput` (such a cell is EXCLUDED from guest emission and renders
    /// native, mirroring `runUIKitLowering`'s exclusion exactly). Its only native residue —
    /// the thunk's custom-slot / host-token closures + wired action ids + replayed effects —
    /// is hashed via `nativeSurfaceByFile`, so editing any of THAT still trips the gate.
    /// - Parameter shippedCells: when non-nil (a build manifest was present), the
    ///   AUTHORITATIVE set of cell/VC type names the build actually shipped OTA — only
    ///   THESE bodies are stripped. The UIKit path converges ONCE with NO per-cell bisect,
    ///   so one bad cell demotes the whole wrapper → ZERO cells ship; a statically-lowerable
    ///   cell can therefore render native and its body must stay hashed [R2-#11]. nil → no
    ///   build yet → strip the full static set (the enforced gate in push/release passes a
    ///   fresh manifest). The native SURFACE is folded in regardless.
    static func loweredUIKitCellData(
        projectDir: URL, registry: NativeRegistry, shippedCells: Set<String>? = nil
    ) -> LoweredViewFingerprintData {
        let lowering = UIKitCellLowering()
        // file path -> { cellTypeName : (methodSignature(s), nativeSurface) }
        var cellsByFile: [String: [(type: String, method: String, surface: String)]] = [:]
        var seenExports = Set<String>()
        for (key, source) in Self.crossFileLoweringSources(projectDir: projectDir) {
            // Cheap pre-filter, identical to `runUIKitLowering`'s.
            guard source.contains("Cell") || source.contains("ReusableView")
                    || source.contains("UIViewController") || source.contains("UIView")
            else { continue }
            for cell in lowering.lowerAllCells(source: source) {
                // SHIP gate: a colliding export OR a non-reconstructable model field means the
                // cell does NOT ship OTA (renders native) — mirror `runUIKitLowering` exactly.
                let sym = UIKitGuestEmitter.exportSymbol(forCell: cell.typeName)
                guard seenExports.insert(sym).inserted else { continue }
                guard !cell.referencesUnmarshalledInput else { continue }
                cellsByFile[key, default: []].append(
                    (type: cell.typeName, method: cell.methodName, surface: Self.nativeSurface(ofCell: cell)))
            }
        }
        guard !cellsByFile.isEmpty else { return LoweredViewFingerprintData() }

        var data = LoweredViewFingerprintData()
        if let report = try? PartitioningEngine(registry: registry).analyze(directory: projectDir) {
            for rec in report.records.values where rec.kind == .method || rec.kind == .initializer {
                // id is `<Module>.<EnclosingType>.<signature>` — match the cell type + its
                // construction-method signature (e.g. `configure(with:)`, `setupViews()`).
                let parts = rec.id.split(separator: ".").map(String.init)
                guard parts.count >= 2 else { continue }
                let signature = parts[parts.count - 1]
                let enclosingType = parts[parts.count - 2]
                let key = rec.sourceFile.standardizedFileURL.path
                guard let cells = cellsByFile[key] else { continue }
                guard cells.contains(where: { $0.type == enclosingType && $0.method == signature })
                else { continue }
                // [R2-#11] BUILD-CONFIRMED INTERSECTION: with a manifest present, strip only
                // a cell body the build SHIPPED (a demoted-whole-wrapper cell stays hashed).
                if let shippedCells, !shippedCells.contains(enclosingType) { continue }
                data.bodySpansByFile[key, default: []].append((start: rec.startLine, end: rec.endLine))
            }
        }
        // The cell native surface is hashed regardless of whether we located the body span
        // (a span we can't locate just means that body isn't stripped — strictly safer).
        for (key, cells) in cellsByFile {
            let frags = cells.map { "C:\($0.type)|\($0.method)|\($0.surface)" }.sorted()
            if !frags.isEmpty { data.nativeSurfaceByFile[key] = frags.joined(separator: "\u{1}") }
        }
        return data
    }

    /// The COMPLETE native code the thunk derives from a lowered UIKit cell's construction —
    /// custom slots, host tokens, wired action ids, gesture wirings, observer effects, and
    /// quarantined native effects. Hashing this is what keeps stripping the cell body sound:
    /// editing any of THIS native residue churns, while editing the lowered (WASM) content
    /// does not. Sorted for determinism.
    static func nativeSurface(ofCell cell: UIKitCellLowering.LoweredCell) -> String {
        var parts: [String] = []
        for leaf in cell.customSlots where leaf.slotable && !leaf.source.isEmpty {
            parts.append("S:\(leaf.id)|\(leaf.source)")
        }
        for tok in cell.hostTokens {
            parts.append("T:\(tok.id)|\(tok.kind.rawValue)|\(tok.source)")
        }
        for a in cell.actionIDs { parts.append("A:\(a)") }
        for g in cell.gestureWirings { parts.append("G:\(g.viewNodeID)|\(g.source)") }
        for o in cell.observerEffects { parts.append("O:\(o.id)|\(o.source)") }
        for e in cell.nativeEffects { parts.append("N:\(e.ordinal)|\(e.source)") }
        return parts.sorted().joined(separator: "\u{2}")
    }

    /// Whether a lowered SwiftUI view is PURELY-OTA — safe to strip its body span
    /// from the native-shell fingerprint (see `loweredViewBodySpans` for the full
    /// soundness argument). All conditions must hold; any doubt → not purely-OTA.
    static func isPurelyOTALowered(_ lowered: BodyLowering.LoweredView) -> Bool {
        // No native slot closures baked into the signed binary (a mixed view's
        // `.opaque` leaves ARE native code the patch can't carry).
        guard lowered.opaqueLeaves.isEmpty else { return false }
        // Not excluded from guest emission → it actually ships OTA (vs renders native).
        guard !lowered.referencesUnmarshalledInput else { return false }
        guard !lowered.referencesUnresolvedSymbol else { return false }
        // The build's auto-route precondition (a pure routing/layout shell stays native).
        guard lowered.report.hasLoweredContentNode else { return false }
        // A view with an undispatchable action-list Button demotes to native (the build
        // keeps it native), so its body is NOT purely-OTA — must stay hashed.
        guard !lowered.hasUndispatchableAction else { return false }
        // Same for a view with a dead/destructive behavioral/lifecycle modifier the engine
        // couldn't slot — it demotes to native in the build, so it is NOT purely-OTA.
        guard !lowered.hasUndispatchableEffect else { return false }
        // A view with a NATIVE EFFECT-MODIFIER SLOT has native residue (its `__patchEffectSlots()`
        // closures are baked into the signed binary, the patch can't carry them), so it is NOT
        // purely-OTA — its body still ships OTA via the auto-routed body-strip path, whose
        // `nativeSurface` folds the effect source; but the stricter purely-OTA strip must skip it.
        guard lowered.effectSlots.isEmpty else { return false }
        // Belt-and-suspenders: every element rode WASM (nothing native left).
        guard lowered.report.coverage >= 1.0 else { return false }
        return true
    }

    /// PARAMETERIZED NATIVE SLOTS — per native source file, the UTF-8 byte ranges of
    /// every SIMPLE STRING LITERAL that the SwiftUI lowering LIFTED out of a slotted
    /// custom-view call into a parameterized slot (`DisplayText(text: "Settings")` →
    /// the `"Settings"` span). Such a literal rides WASM via `BodyEmission.slotArgs`
    /// and the build-time thunk's slot factory is literal-INDEPENDENT, so editing it
    /// is a genuine OTA change that does NOT alter the signed binary. The fingerprint
    /// walker normalizes EXACTLY these byte ranges to a stable placeholder before
    /// hashing, so a string edit keeps the native-shell fingerprint stable WHILE a
    /// non-string edit (a number/arg/structure change to the same slot) still trips
    /// the gate (its bytes are untouched). This is SURGICAL (only the lifted literals)
    /// and therefore sound regardless of what else the view contains — a nested or
    /// non-lifted string in a native slot is NOT in these ranges and stays hashed.
    /// Empty map if analysis fails (the caller then hashes those literals as before —
    /// never weaker than the pre-fix gate).
    ///
    /// [R2-#12] We collect a leaf's lifted-literal ranges ONLY for a view whose body
    /// is EMITTED to WASM AND whose parameterized-slot string literals provably ride
    /// `BodyEmission.slotArgs` — regardless of whether ALL opaque leaves are slotable.
    /// A view EXCLUDED from WASM emission (reads an unmarshalled input, references an
    /// unresolved symbol, shares a colliding export base, or is thunk-ineligible) renders
    /// its entire `body` from the SIGNED binary: its slot literals are native content that
    /// must churn. Likewise, a view whose WHOLE-BODY demote comes from an undispatchable
    /// action or effect renders native — its literals stay hashed (the R2-#12 case).
    ///
    /// A view that LOWERS but has a non-slotable opaque leaf (thunkSafe=false) does NOT
    /// normalize its lifted literals. The SDK's `entryIfPatchable` returns nil for a
    /// non-thunkSafe entry, so the thunk always falls through to the ORIGINAL native `body`.
    /// That body uses the COMPILED-IN literal — the WASM module's `slotArgs` are never read.
    /// Normalizing the literal byte ranges would therefore cause a SILENT DROP: `release`
    /// reports ✓ compatible, ships a patch, but the device renders the OLD value forever.
    /// A MISMATCH (the safe failure) is better: the dev knows the native binary must be
    /// rebuilt. `hasOTAParameterizedSlotLiterals` now includes the allSatisfy{slotable}
    /// guard so non-thunkSafe views keep their literals hashed verbatim → editing churns.
    ///
    /// When a build manifest is present we further intersect with the SHIPPED views (a
    /// statically-lowered view the build dropped to native also keeps its literals hashed).
    /// - Parameter shippedViews: see `loweredAutoRoutedViewData`. nil → static fallback.
    static func loweredParameterizedSlotLiteralRanges(
        projectDir: URL, registry: NativeRegistry, shippedViews: Set<String>? = nil
    ) -> [String: [Range<Int>]] {
        let lowering = BodyLowering()
        var ranges: [String: [Range<Int>]] = [:]
        // PASS 0 — the SHARED source set (incl. model-class files), IDENTICAL by construction to the
        // build's lowering source set, so the opaque-leaf set — and thus the lifted-literal ranges —
        // matches what the build ships.
        let fileSources = Self.crossFileLoweringSources(projectDir: projectDir)
        guard !fileSources.isEmpty else { return [:] }
        let crossFile = BodyLowering.crossFileBundle(sources: fileSources.map(\.source))
        // PASS 1 — lower every file once + count export bases (collision detection, the
        // SAME way `loweredAutoRoutedViewData` does), so we know which views auto-route.
        var loweredByFile: [String: [BodyLowering.LoweredView]] = [:]
        var exportBaseCounts: [String: Int] = [:]
        for (key, source) in fileSources {
            guard source.contains("View") else { continue }
            let lowered = lowering.lowerAllViews(source: source, sameFileThunk: Self.sameFileThunkEnabled, crossFile: crossFile)
            loweredByFile[key] = lowered
            for lv in lowered where lv.report.totalElements > 0 {
                exportBaseCounts[SwiftUIGuestEmitter.exportSymbol(forView: lv.viewName), default: 0] += 1
            }
        }
        let collidingBases = Set(exportBaseCounts.filter { $0.value > 1 }.keys)
        let thunkIneligible = BuildPipeline.thunkIneligibleViewNames(sources: fileSources.map(\.source))
        // PASS 2 — collect lifted-literal ranges for any view that:
        //   (a) is EMITTED to WASM (not excluded by the hard gates), AND
        //   (b) has at least one parameterized opaque leaf with lifted string-literal ranges.
        // A view that is EXCLUDED from WASM emission (unmarshalledInput / unresolvedSymbol /
        // collidingBases / thunkIneligible) or whose WHOLE BODY demotes due to an undispatchable
        // action or effect renders from the SIGNED binary → literals stay hashed verbatim
        // (the R2-#12 false-stable guard). A view that LOWERS but has a non-slotable leaf
        // (thunkSafe=false) DOES NOT normalize its literals — the SDK returns nil from
        // `entryIfPatchable` (thunkSafe gate) and the thunk renders the ORIGINAL native body,
        // so the WASM slotArgs are never consumed. Normalizing would cause a SILENT DROP.
        // `hasOTAParameterizedSlotLiterals` now requires allSatisfy{slotable} for this reason.
        // The body-span strip is unchanged (only auto-routed view bodies are stripped —
        // see `loweredAutoRoutedViewData`).
        for (key, lowereds) in loweredByFile {
            var fileRanges: [Range<Int>] = []
            for lowered in lowereds {
                guard Self.hasOTAParameterizedSlotLiterals(
                    lowered, collidingBases: collidingBases, thunkIneligible: thunkIneligible
                ) else { continue }
                if let shippedViews, !shippedViews.contains(lowered.viewName) { continue }
                for leaf in lowered.opaqueLeaves {
                    fileRanges.append(contentsOf: leaf.stringArgRanges)
                }
            }
            if !fileRanges.isEmpty { ranges[key] = fileRanges }
        }
        return ranges
    }

    /// True when a lowered view's parameterized-slot string-literal values PROVABLY ride
    /// `BodyEmission.slotArgs` in the WASM module AND the view is thunkSafe (the SDK
    /// auto-routes it via the thunk → WASM) — meaning editing only those literals does not
    /// change the signed binary and should not churn the native-shell fingerprint.
    ///
    /// This is NOW EQUIVALENT to `isAutoRouted` for the slotability gate: it REQUIRES
    /// `opaqueLeaves.allSatisfy({ $0.slotable })`. A non-thunkSafe view (a non-slotable leaf)
    /// NEVER routes to WASM on-device — the SDK's `entryIfPatchable` returns nil and the
    /// thunk falls back to the original native `body`. Normalizing its lifted literals would
    /// cause a SILENT DROP: the signed binary always renders the OLD value while `release`
    /// reports ✓ compatible. A MISMATCH (the safe failure) is strictly better.
    ///
    /// The HARD exclusion gates are all preserved:
    ///   - `thunkIneligible` / `collidingBases` — view is never thunked → body fully native
    ///   - `referencesUnmarshalledInput` / `referencesUnresolvedSymbol` — view EXCLUDED from
    ///     WASM emission entirely (body stays native, slot literals are native content)
    ///   - `hasUndispatchableAction` / `hasUndispatchableEffect` — WHOLE-BODY demote: the
    ///     body renders from the SIGNED binary on device (the undispatchable action/effect
    ///     can't run natively from a WASM path), so literals stay native and must churn
    ///   - `totalElements == 0` — body emits nothing, no slot args exist
    ///   - `!opaqueLeaves.allSatisfy({ $0.slotable })` — non-thunkSafe → renders native →
    ///     WASM slotArgs are never consumed → literals must churn (MISMATCH, not silent drop)
    private static func hasOTAParameterizedSlotLiterals(
        _ lv: BodyLowering.LoweredView, collidingBases: Set<String>,
        thunkIneligible: Set<String> = []
    ) -> Bool {
        if thunkIneligible.contains(lv.viewName) { return false }
        if collidingBases.contains(SwiftUIGuestEmitter.exportSymbol(forView: lv.viewName)) { return false }
        if lv.referencesUnmarshalledInput || lv.referencesUnresolvedSymbol { return false }
        guard lv.report.totalElements > 0 else { return false }
        // Whole-body demote: body renders from the SIGNED binary, literals are native.
        if lv.hasUndispatchableAction { return false }
        if lv.hasUndispatchableEffect { return false }
        // GUARD: every opaque leaf MUST be slotable — i.e. the view is thunkSafe (the SDK
        // auto-routes it via the thunk → WASM). If ANY leaf is non-slotable, `thunkSafe=false`
        // and the SDK's `entryIfPatchable` returns nil → the thunk falls back to the ORIGINAL
        // NATIVE `body` (the compiled-in code). In that case the WASM module is NEVER called
        // on-device, so its `slotArgs` are never consumed. Normalizing the literal byte ranges
        // then causes a SILENT DROP: `release` reports ✓ compatible, ships a patch whose new
        // string rides WASM, but the device renders the OLD compiled-in literal forever.
        // A MISMATCH (the safe failure) is strictly better — the dev knows the native binary
        // must be rebuilt. Require all leaves slotable (= thunkSafe) before normalizing.
        guard lv.opaqueLeaves.allSatisfy({ $0.slotable }) else { return false }
        return lv.opaqueLeaves.contains { !$0.stringArgRanges.isEmpty }
    }

    /// Hash a native source file with the BODIES of its OTA-eligible functions
    /// neutralized, so a body-only edit to patchable code does not change the
    /// native-shell fingerprint. The function's SIGNATURE line (`startLine`) is kept
    /// verbatim — a signature change (the function's ABI surface) still trips the
    /// gate — and only the strictly-interior lines (`startLine+1 ... endLine`) are
    /// replaced with a stable marker. When there are no eligible spans (or analysis
    /// was unavailable) this is identical to hashing the raw bytes.
    static func shellNormalizedHash(of url: URL, eligibleSpans: [(start: Int, end: Int)]?,
                                    slotLiteralRanges: [Range<Int>]? = nil,
                                    nativeSurfaceSuffix: String? = nil) -> String {
        guard var text = try? String(contentsOf: url, encoding: .utf8) else {
            // Unreadable as UTF-8 → hash raw bytes, unchanged behavior.
            guard let data = try? Data(contentsOf: url) else { return "" }
            return Fingerprinter.hashData(data)
        }
        // PARAMETERIZED NATIVE SLOTS: normalize each lifted string literal to a stable
        // placeholder FIRST (it rides WASM via `slotArgs`; the native slot factory is
        // literal-independent). Done before line-span stripping so line numbers are
        // unaffected — a single-segment string literal is always on one line, and the
        // placeholder carries no newline, so line COUNT is invariant. Ranges are
        // applied in DESCENDING start order so earlier UTF-8 offsets stay valid.
        if let lits = slotLiteralRanges, !lits.isEmpty {
            text = Self.normalizeByteRanges(in: text, ranges: lits)
        }
        let spans = eligibleSpans ?? []
        // `patchcli prepare` (which now runs AUTOMATICALLY before every build/push/
        // release) appends a `// PATCH-THUNKS-BEGIN … // PATCH-THUNKS-END` block to
        // every file declaring a patchable view and inserts a `dynamic` modifier on
        // each patchable `var body`. That scaffolding is pure Patch machinery —
        // regenerated wholesale on every prepare — NOT the developer's native shell,
        // so it MUST NOT change the fingerprint. Otherwise registering a fingerprint
        // BEFORE prepare has run (e.g. right after `init`, before the first build) and
        // then `release` auto-preparing produces a guaranteed MISMATCH on a project
        // the developer never actually changed — the exact churn the fingerprint is
        // designed to avoid. See `stripPatchScaffolding`.
        // [R2-#127] Match the EXACT generated begin marker (not the short literal a
        // developer could legitimately type in a comment), AND require a matching END —
        // otherwise a stray `// PATCH-THUNKS-BEGIN …` comment would eat every following
        // real native line. `stripPatchScaffolding` re-checks both conditions itself.
        let isPrepared = text.contains(ThunkGenerator.sameFileBeginMarker)
            && text.contains(ThunkGenerator.sameFileEndMarker)
        let hasSlotLiterals = !(slotLiteralRanges ?? []).isEmpty
        let hasNativeSurface = !(nativeSurfaceSuffix ?? "").isEmpty
        // SELF-REFERENTIAL FINGERPRINT LITERAL: `patchcli init` bakes the native-shell
        // fingerprint into the `@main` App's `Patch.configure(.init(… fingerprint: "…"))`
        // call. That value is the hash's OWN output, so hashing it verbatim is circular —
        // the fingerprint would depend on a copy of itself, and re-baking it (init, or a
        // later re-register) would move the hash and trip the gate on a project the
        // developer never changed. Normalize that one literal VALUE to a placeholder so the
        // native-shell hash is INVARIANT to whatever fingerprint is baked in (the rest of
        // the configure call — appKey/appID/structure — is still hashed as real shell).
        let hasConfigureFP = text.contains("Patch.configure(")
            && text.range(of: #"fingerprint:\s*"[^"]*""#, options: .regularExpression) != nil
        // FAST PATH / zero churn: a file with no OTA-eligible body span, no prepare
        // scaffolding, no lifted parameterized-slot literal, no baked configure fingerprint
        // AND no auto-routed-view native surface is hashed byte-for-byte exactly as before,
        // so existing registered fingerprints are bit-identical for every unaffected file.
        // (When any of those applied, `text` is no longer the raw bytes / carries an appended
        // surface, so we must hash the normalized form — the slow path.)
        if spans.isEmpty && !isPrepared && !hasSlotLiterals && !hasNativeSurface && !hasConfigureFP {
            guard let data = try? Data(contentsOf: url) else { return "" }
            return Fingerprinter.hashData(data)
        }
        var normalized = text
        // Normalize the baked configure fingerprint FIRST — a single-line value replace that
        // never changes the line COUNT, so the eligible-span line numbers below stay valid.
        if hasConfigureFP { normalized = Self.normalizeConfigureFingerprint(normalized) }
        if !spans.isEmpty { normalized = normalize(source: normalized, strippingBodiesOf: spans) }
        if isPrepared { normalized = stripPatchScaffolding(normalized) }
        // Fold the auto-routed views' NATIVE SURFACE (the thunk's slot/token/row-slot
        // closures — the only native code derived from a stripped body) back into the
        // hash, so a slot/token/row-slot edit STILL churns even though the body is stripped.
        if hasNativeSurface { normalized += "\n\u{1}NATIVE-SURFACE\u{1}\n" + (nativeSurfaceSuffix ?? "") }
        return Fingerprinter.hash(normalized)
    }

    /// Replace the VALUE of the baked `fingerprint: "…"` literal inside a
    /// `Patch.configure(.init(…))` call with a stable placeholder, so the native-shell
    /// hash is INVARIANT to whatever native-shell fingerprint `patchcli init` (or a later
    /// re-register) bakes into the developer's `@main` App file. The fingerprint is the
    /// hash's own output; hashing it verbatim is self-referential — re-baking it would
    /// move the hash and false-MISMATCH the gate. Only the value BETWEEN the quotes is
    /// normalized; `fingerprint: "` and the closing `"` (and the rest of the configure
    /// call — appKey/appID/structure) stay hashed verbatim, so a real shell change still
    /// churns. Operates only when the file actually contains a `Patch.configure(` call.
    static func normalizeConfigureFingerprint(_ source: String) -> String {
        guard source.contains("Patch.configure("),
              let regex = try? NSRegularExpression(pattern: #"(fingerprint:\s*")[^"]*(")"#)
        else { return source }
        let range = NSRange(source.startIndex..., in: source)
        return regex.stringByReplacingMatches(
            in: source, range: range, withTemplate: "$1\u{1}FP\u{1}$2")
    }

    /// Replace each UTF-8 byte range in `text` with a stable placeholder (the
    /// parameterized-slot string literals — they ride WASM, so their VALUE is OTA and
    /// must not affect the native-shell hash). Ranges are clamped + applied in
    /// DESCENDING start order so earlier offsets stay valid, and out-of-bounds /
    /// overlapping ranges are skipped defensively (a stale range never corrupts the
    /// hash — worst case it's left hashed, never a crash). The placeholder is a fixed
    /// token, so two source variants differing ONLY in lifted literals normalize
    /// byte-identically.
    static func normalizeByteRanges(in text: String, ranges: [Range<Int>]) -> String {
        guard !ranges.isEmpty else { return text }
        var bytes = Array(text.utf8)
        let placeholder = Array("\u{1}LIT\u{1}".utf8)
        // Sort descending by start; drop invalid / overlapping (defensive).
        let sorted = ranges.sorted { $0.lowerBound > $1.lowerBound }
        var lastLower = bytes.count + 1
        for r in sorted {
            guard r.lowerBound >= 0, r.upperBound <= bytes.count, r.lowerBound < r.upperBound,
                  r.upperBound <= lastLower else { continue }
            bytes.replaceSubrange(r.lowerBound..<r.upperBound, with: placeholder)
            lastLower = r.lowerBound
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Reverse `patchcli prepare`'s two deterministic, fully-regenerated source
    /// insertions so a file's native-shell hash is INVARIANT to whether prepare has
    /// run: (1) the `// PATCH-THUNKS-BEGIN … // PATCH-THUNKS-END` thunk block prepare
    /// appends to every file declaring a patchable view, and (2) the `dynamic`
    /// modifier prepare inserts before each patchable `var body` / cell
    /// `func configure(with:)`. Both are Patch scaffolding (the marker block even says
    /// "Regenerated wholesale on every `patchcli prepare`"), never the developer's
    /// own code, so they must never contribute to fingerprint churn. A developer's
    /// OWN `dynamic` on any OTHER declaration is left intact (it IS native shell —
    /// e.g. a `dynamic func` that genuinely runs natively).
    static func stripPatchScaffolding(_ source: String) -> String {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // [R2-#127] The block boundary is the EXACT generated marker — `trimmed == marker`,
        // NOT a short `hasPrefix("// PATCH-THUNKS-BEGIN")`. A developer hand-annotating a
        // comment that merely BEGINS with that prefix (`// PATCH-THUNKS-BEGIN region`) must
        // not be mistaken for prepare's scaffolding and have all following real native code
        // dropped from the hash (a FALSE-STABLE). We ALSO require a matching END line to
        // exist: if a begin marker has no closing end (a truncated paste), strip NOTHING for
        // the block — never let an unbounded block eat real source to EOF.
        let beginMarker = ThunkGenerator.sameFileBeginMarker
        let endMarker = ThunkGenerator.sameFileEndMarker
        func isBegin(_ trimmed: Substring) -> Bool { trimmed == beginMarker[...] }
        func isEnd(_ trimmed: Substring) -> Bool { trimmed == endMarker[...] }
        // Pre-scan: only treat a begin marker as a real block opener if a matching end
        // marker appears AFTER it (so a stray/unterminated begin can never eat to EOF).
        var hasTerminatedBlock = false
        var sawBegin = false
        for line in lines {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            if isBegin(trimmed) { sawBegin = true }
            else if sawBegin && isEnd(trimmed) { hasTerminatedBlock = true; break }
        }
        var out: [String] = []
        out.reserveCapacity(lines.count)
        var inThunkBlock = false
        for line in lines {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            if hasTerminatedBlock, isBegin(trimmed) { inThunkBlock = true; continue }
            if inThunkBlock {
                if isEnd(trimmed) { inThunkBlock = false }
                continue
            }
            out.append(stripInsertedDynamicModifier(line))
        }
        return out.joined(separator: "\n")
    }

    /// Remove the `dynamic` modifier `patchcli prepare` inserts before a patchable
    /// `var body` / cell `func configure(with:)` declaration, leaving the leading
    /// indentation and any developer access modifiers intact. Operates ONLY on the
    /// modifier prefix BEFORE the `var body` / `func configure(` token — so a
    /// `dynamic` appearing in body content or a string literal is never touched, and
    /// a developer's own `dynamic func foo()` (not a body/configure) is left as-is.
    /// [R2-#14] The FULL set of method NAMES `patchcli prepare` (`UIKitThunkGenerator`)
    /// can make `dynamic` — the SwiftUI `var body`, the cell `configure(with:)`, and EVERY
    /// programmatic-VC/cell construction hook (`UIKitClassifier.setupNames` ∪ `vcSetupNames`
    /// ∪ `{viewDidLoad}`). If `declStart` only recognized `configure`/`body`, prepare's
    /// inserted `dynamic` before a `setupViews()`/`viewDidLoad()` survived the strip → the
    /// file hashed differently before vs after auto-prepare → a false MISMATCH on a project
    /// the developer never changed. Lowercased (matched case-insensitively against the source
    /// token, as the classifier itself does). `configure` matches `func configure(` (any args).
    static let dynamicMethodNames: Set<String> = {
        var names: Set<String> = ["configure", "viewdidload"]
        names.formUnion(["setup", "setupviews", "setupui", "setupcell",
                         "setupsubviews", "configureviews", "commoninit"])   // UIKitClassifier.setupNames
        names.formUnion(["setupviews", "setupui", "setupsubviews", "configureviews", "setuplayout",
                         "buildviews", "buildui", "configuresubviews", "configureui", "addsubviews",
                         "installviews", "setuphierarchy", "setupconstraints"])   // UIKitClassifier.vcSetupNames
        return names
    }()

    static func stripInsertedDynamicModifier(_ line: String) -> String {
        // Locate a patchable-decl keyword: `var body` as a whole identifier
        // (NOT `var bodyText`) or a `func <name>(` for any construction method name
        // prepare can mark dynamic (`configure`, `setupViews`, `viewDidLoad`, …).
        func declStart() -> String.Index? {
            // [R2-#14] Match `func <name>(` for any of the prepare-dynamic method names.
            var fsearch = line.startIndex
            while let r = line.range(of: "func ", range: fsearch..<line.endIndex) {
                // Read the identifier after `func `.
                var i = r.upperBound
                var name = ""
                while i < line.endIndex, line[i] == " " || line[i] == "\t" { i = line.index(after: i) }
                while i < line.endIndex, line[i].isLetter || line[i].isNumber || line[i] == "_" {
                    name.append(line[i]); i = line.index(after: i)
                }
                // Skip whitespace then require an opening `(` (a method decl, not a use).
                var j = i
                while j < line.endIndex, line[j] == " " || line[j] == "\t" { j = line.index(after: j) }
                if j < line.endIndex, line[j] == "(", Self.dynamicMethodNames.contains(name.lowercased()) {
                    return r.lowerBound
                }
                fsearch = r.upperBound
            }
            var search = line.startIndex
            while let r = line.range(of: "var body", range: search..<line.endIndex) {
                let after = r.upperBound
                if after == line.endIndex || !(line[after].isLetter || line[after].isNumber || line[after] == "_") {
                    return r.lowerBound
                }
                search = r.upperBound
            }
            return nil
        }
        guard let declIdx = declStart() else { return line }
        let prefix = String(line[line.startIndex..<declIdx])
        guard prefix.contains("dynamic") else { return line }
        let rest = String(line[declIdx...])
        let leadingWS = String(prefix.prefix(while: { $0 == " " || $0 == "\t" }))
        var mods = prefix.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        mods.removeAll { $0 == "dynamic" }
        let modStr = mods.isEmpty ? "" : (mods.joined(separator: " ") + " ")
        return leadingWS + modStr + rest
    }

    /// Replace the interior body lines of each eligible function span with a stable
    /// placeholder. Line numbers are 1-based (matching `FunctionRecord`). Overlapping
    /// / nested spans are handled by marking any interior line covered by ANY span.
    static func normalize(source: String, strippingBodiesOf spans: [(start: Int, end: Int)]) -> String {
        // Preserve the exact line split (don't collapse a trailing newline) so two
        // genuinely-different shells can't normalize to the same text.
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Mark interior lines (strictly after the signature line, up to & including
        // the closing-brace line) of every eligible span. Keeping the signature line
        // means a signature edit still changes the hash.
        var stripped = Set<Int>()
        // [BUG #68] A SINGLE-LINE body (`var body: some View { Text("Hello") }` /
        // `func go() -> Int { 1 + 1 }`) has `start == end`, so the multi-line interior
        // strip below (which needs `end > start`) never touched it — its lowered content
        // (a `Text` leaf riding WASM) stayed hashed verbatim and a pure-OTA literal edit
        // churned the fingerprint, wrongly refusing the push. For such a span we strip the
        // OUTERMOST brace INTERIOR of that line in-place (keeping the signature prefix and
        // the closing `}`) — the analogue of the multi-line interior strip: a body-content
        // edit is now stable, while a SIGNATURE edit (outside the braces) still churns.
        var singleLineBodyLines = Set<Int>()
        for s in spans {
            if s.end > s.start {
                for line in (s.start + 1)...s.end { stripped.insert(line) }
            } else if s.end == s.start {
                singleLineBodyLines.insert(s.start)
            }
        }
        guard !stripped.isEmpty || !singleLineBodyLines.isEmpty else { return source }
        var out: [String] = []
        out.reserveCapacity(lines.count)
        var i = 1
        var inStrippedRun = false
        for line in lines {
            if stripped.contains(i) {
                // Collapse a contiguous stripped run to ONE marker so reformatting the
                // body (line count change) still normalizes identically.
                if !inStrippedRun { out.append("\u{0001}OTA_BODY\u{0001}"); inStrippedRun = true }
            } else if singleLineBodyLines.contains(i) {
                out.append(Self.stripBraceInterior(line))
                inStrippedRun = false
            } else {
                out.append(line)
                inStrippedRun = false
            }
            i += 1
        }
        return out.joined(separator: "\n")
    }

    /// [BUG #68] Replace the content between the FIRST `{` and the LAST `}` on a single
    /// line with a stable marker, leaving everything up to & including the opening brace
    /// (the declaration's signature) and the trailing close brace + any suffix intact.
    /// So `var body: some View { Text("Hello") }` → `var body: some View {\u{1}OTA_BODY\u{1}}`.
    /// Editing the body content normalizes identically; editing the signature (outside the
    /// braces) still changes the hash. If the line has no balanced `{ … }` pair we return it
    /// unchanged (strictly safer — it stays hashed verbatim).
    static func stripBraceInterior(_ line: String) -> String {
        guard let open = line.firstIndex(of: "{"), let close = line.lastIndex(of: "}"),
              open < close else { return line }
        let prefix = line[line.startIndex...open]
        let suffix = line[close...]
        return String(prefix) + "\u{0001}OTA_BODY\u{0001}" + String(suffix)
    }

    // MARK: - Helpers

    /// Whether an `exclude` entry matches a file. An exclude is one of:
    ///   - an exact relative path (`Sources/App/AppDelegate.swift`),
    ///   - a bare file name (`AppDelegate.swift`), or
    ///   - a DIRECTORY prefix (`Sources/Generated/` or `Sources/Generated`).
    ///
    /// The prefix match is ANCHORED on a path-segment boundary: an entry
    /// `Sources/App` excludes `Sources/App/...` but NOT the sibling file
    /// `Sources/AppDelegate.swift`. The old bare `rel.hasPrefix(entry)` over-matched
    /// — e.g. exclude `Generated` silently dropped `GeneratedHelpers.swift` (a real
    /// NATIVE file) from the fingerprint, so a native-shell change to it would slip
    /// past the OTA-compatibility gate and ship an incompatible module.
    static func excludeMatches(_ entry: String, relativePath rel: String, fileName: String) -> Bool {
        guard !entry.isEmpty else { return false }
        if fileName == entry { return true }
        if rel == entry { return true }
        // Directory prefix: normalize a trailing slash, then require the next char
        // in `rel` to be the path separator (a true segment boundary).
        let dir = entry.hasSuffix("/") ? String(entry.dropLast()) : entry
        guard !dir.isEmpty else { return false }
        return rel == dir || rel.hasPrefix(dir + "/")
    }

    private func relativePath(_ url: URL, base: URL) -> String {
        let basePath = base.standardizedFileURL.path
        let p = url.standardizedFileURL.path
        if p.hasPrefix(basePath) {
            return String(p.dropFirst(basePath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return url.lastPathComponent
    }

    /// [BUG-3] The ONE walk every fingerprint sub-component shares, so they all agree
    /// on what "the native shell" is. Yields only developer-owned files (regular
    /// files, hidden entries skipped), PRUNING whole build-artifact / dependency /
    /// engine-output subtrees (`skipDescendants`) — SwiftPM `checkouts`/`SourcePackages`,
    /// `DerivedData`, CocoaPods, Carthage, the engine's own `.patch`/`.swiftpm`. Every
    /// helper below (native files, Info.plist, entitlements, frameworks, deployment
    /// target) MUST funnel through this; the old per-helper raw enumerators silently
    /// picked a *dependency's* Info.plist / Package.swift / project.pbxproj or inferred
    /// frameworks from dependency imports, all of which churned the fingerprint.
    private func shellFiles(in dir: URL, fm: FileManager) -> [URL] {
        var out: [URL] = []
        guard let e = fm.enumerator(at: dir,
                                    includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                                    options: [.skipsHiddenFiles]) else { return out }
        for case let f as URL in e {
            let lowerPath = f.path.lowercased()
            let isDir = (try? f.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                // `+ "/"` lets the parser's slash-anchored predicate match the bare
                // directory path (…/checkouts → …/checkouts/), pruning the subtree.
                let n = f.lastPathComponent
                if n == ".patch" || n == ".swiftpm"
                    || SwiftParserEngine.isBuildArtifactPath(lowerPath + "/") {
                    e.skipDescendants()
                }
                continue
            }
            if lowerPath.contains("/.patch/") || lowerPath.contains("/.swiftpm/") { continue }
            if SwiftParserEngine.isBuildArtifactPath(lowerPath) { continue }
            // [BUG-1] A custom `--output` dir defeats the `/.patch/` location skip — the
            // engine's generated support family (`_PatchFusionShims`/`_PatchHelper_*`/
            // `_PatchNamespaces`/`_PatchType_*`/`_PatchGenerics`/…) lands outside `.Patch/`
            // and would be hashed as native shell → spurious fingerprint churn. Skip by
            // NAME so the exclusion is location-independent.
            if f.lastPathComponent.hasPrefix("_Patch") { continue }
            out.append(f)
        }
        return out
    }

    private func contentHash(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        // Hash the RAW bytes so a binary / non-UTF-8 file (a binary Info.plist, a
        // compiled asset) is hashed byte-exactly. The old lossy `String(decoding:)`
        // collapsed every invalid byte to U+FFFD, so two different binaries could
        // hash identically and a native-shell change would slip past the gate.
        return Fingerprinter.hashData(data)
    }

    /// [BUG #67] Whether a non-`.swift` shell input (Info.plist / .entitlements /
    /// project.pbxproj) belongs to a TEST or UI-TEST target rather than the shipped app.
    /// Such a file compiles into a SEPARATE test bundle, never the signed app binary, so
    /// editing it (a test bundle id, a test permission string) CANNOT change the OTA
    /// module or the binary the patch runs against — it must not churn the app fingerprint.
    ///
    /// `SwiftParserEngine.isTestFile` keys on `/tests/` etc. and on a `…Tests.swift`
    /// BASENAME — neither catches an `AppUITests/Info.plist` (its basename is `Info.plist`
    /// and its directory `AppUITests` is not the lowercased `/tests/` segment). So we ALSO
    /// reject a file under a directory SEGMENT whose name ends in the conventional test-target
    /// suffix.
    ///
    /// [BUG] Use ONLY the unambiguous PLURAL Xcode/Quick conventions — `Tests`, `UITests`,
    /// `Specs` — and NEVER the SINGULAR `Test`/`UITest`/`Spec`. A singular `…Test`/`…Spec`
    /// directory (`SpeedTest/`, `LoadTest/`, `CheckoutSpec/`) is genuine NATIVE app code far
    /// more often than a test target; excluding its `Info.plist`/`.entitlements`/`pbxproj`
    /// from the fingerprint drops a real native-shell input → false-stable (the patch ships
    /// against a binary whose shell silently changed). This mirrors `isTestFile`'s nuanced
    /// suffix rule (SwiftParserEngine.swift), which deliberately requires corroboration before
    /// treating a singular `*Test`/`*Spec` as a test artifact. Conservative: a real app folder
    /// is virtually never named with the PLURAL `…Tests`/`…UITests`/`…Specs` suffix.
    static func isTestTargetInput(_ url: URL) -> Bool {
        if SwiftParserEngine.isTestFile(url) { return true }
        let segments = url.deletingLastPathComponent().pathComponents
        let suffixes = ["Tests", "UITests", "Specs"]
        for seg in segments where suffixes.contains(where: { seg.hasSuffix($0) }) {
            return true
        }
        return false
    }

    private func firstFileHash(in dir: URL, named name: String, fm: FileManager) -> String {
        // `FileManager.enumerator` order is NOT guaranteed deterministic across
        // platforms / filesystems. A project with MORE THAN ONE `Info.plist` (app +
        // tests + an extension target is common) would then pick a different file on
        // different runs → a DIFFERENT fingerprint for an unchanged shell, producing a
        // spurious OTA-compatibility MISMATCH (blocking a legitimate push) or masking a
        // real change. Collect ALL matches and pick the lexicographically-first path so
        // the fingerprint is deterministic. (Entitlements already sort + combine.)
        // `shellFiles` excludes dependency/artifact trees so we never hash a Firebase /
        // Pods `Info.plist` as if it were the app's ([BUG-3]); TEST-TARGET plists are
        // excluded too ([BUG #67]) — they ship in a separate test bundle, not the app.
        let matches = shellFiles(in: dir, fm: fm)
            .filter { $0.lastPathComponent == name && !Self.isTestTargetInput($0) }
        guard let chosen = matches.min(by: { $0.path < $1.path }) else {
            return ""   // absent → stable empty hash input
        }
        return contentHash(chosen)
    }

    private func firstFileMatchingHash(in dir: URL, ext: String, fm: FileManager) -> String {
        // [BUG #67] A test target's `.entitlements` joins into the app fingerprint here;
        // drop it — it never reaches the shipped binary or the OTA module.
        let hashes = shellFiles(in: dir, fm: fm)
            .filter { $0.pathExtension == ext && !Self.isTestTargetInput($0) }
            .map { contentHash($0) }
        return hashes.sorted().joined(separator: "|")
    }

    /// Infer linked frameworks from `import X` lines across the corpus.
    private func inferFrameworks(in dir: URL, fm: FileManager) -> [String] {
        var found: Set<String> = []
        let frameworkImports: Set<String> = [
            "UIKit", "SwiftUI", "Foundation", "Combine", "CoreData", "CoreLocation",
            "AVFoundation", "MapKit", "CoreBluetooth", "HealthKit", "Metal",
            "CoreGraphics", "UserNotifications", "Network", "WebKit", "StoreKit",
        ]
        // Only the app's OWN sources determine its linked frameworks — dependency
        // imports (excluded by `shellFiles`) and TEST imports (a unit test importing
        // a framework the app never links) must not pollute the set ([BUG-3]).
        for f in shellFiles(in: dir, fm: fm)
            where f.pathExtension == "swift" && !SwiftParserEngine.isTestFile(f) {
            guard let s = try? String(contentsOf: f, encoding: .utf8) else { continue }
            for line in s.split(separator: "\n") {
                if let mod = Self.importedModule(in: String(line)),
                   frameworkImports.contains(mod) { found.insert(mod) }
            }
        }
        if found.isEmpty { found.insert("Foundation") }
        return Array(found)
    }

    /// Extract the top-level module name from an `import` line, returning nil for a
    /// non-import line. Handles the real forms the old exact-match missed (each of
    /// which silently dropped a linked framework from the fingerprint, so a
    /// native-shell change touching it could slip the OTA-compatibility gate):
    ///   * a submodule import — `import UIKit.UIView`        → `UIKit`
    ///   * a kind-qualified import — `import struct Foundation.Data` → `Foundation`
    ///   * `@testable import UIKit`                          → `UIKit`
    ///   * a trailing comment — `import SwiftUI // root view` → `SwiftUI`
    static func importedModule(in line: String) -> String? {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("@testable") {
            t = String(t.dropFirst("@testable".count)).trimmingCharacters(in: .whitespaces)
        }
        guard t.hasPrefix("import ") else { return nil }
        var rest = String(t.dropFirst("import ".count)).trimmingCharacters(in: .whitespaces)
        // Strip a kind qualifier (`struct`/`class`/`enum`/`func`/`var`/`let`/
        // `protocol`/`typealias`) so `import struct Foundation.Data` → `Foundation.Data`.
        let kinds: Set<String> = ["struct", "class", "enum", "func", "var", "let", "protocol", "typealias", "actor"]
        if let firstWord = rest.split(separator: " ").first.map(String.init), kinds.contains(firstWord) {
            rest = String(rest.dropFirst(firstWord.count)).trimmingCharacters(in: .whitespaces)
        }
        // Take the leading identifier (up to whitespace / comment / submodule dot).
        var name = ""
        for ch in rest {
            if ch.isLetter || ch.isNumber || ch == "_" { name.append(ch) } else { break }
        }
        return name.isEmpty ? nil : name
    }

    /// Best-effort deployment target from a project/Package file.
    private func inferDeploymentTarget(in dir: URL, fm: FileManager) -> String? {
        // Package.swift `.iOS(...)` or a project file IPHONEOS_DEPLOYMENT_TARGET.
        let pkg = dir.appendingPathComponent("Package.swift")
        if let s = try? String(contentsOf: pkg, encoding: .utf8) {
            if let r = s.range(of: #"\.iOS\(\.v(\d+)\)"#, options: .regularExpression) {
                let v = s[r].replacingOccurrences(of: ".iOS(.v", with: "").replacingOccurrences(of: ")", with: "")
                return "iOS \(v).0"
            }
        }
        // Deterministic + artifact-pruned: a dependency checked out in-tree carries
        // its OWN `project.pbxproj` with a DIFFERENT deployment target; the old
        // unsorted enumerator could return that one (non-deterministically), pinning
        // the fingerprint to a dependency's iOS target ([BUG-3]). Sort and use the
        // first app/local pbxproj only.
        let pbxprojs = shellFiles(in: dir, fm: fm)
            .filter { $0.lastPathComponent == "project.pbxproj" && !Self.isTestTargetInput($0) }
            .sorted { $0.path < $1.path }
        for f in pbxprojs {
            if let s = try? String(contentsOf: f, encoding: .utf8),
               let r = s.range(of: #"IPHONEOS_DEPLOYMENT_TARGET = ([0-9.]+)"#, options: .regularExpression) {
                let target = s[r].replacingOccurrences(of: "IPHONEOS_DEPLOYMENT_TARGET = ", with: "")
                return "iOS \(target)"
            }
        }
        return nil
    }
}
