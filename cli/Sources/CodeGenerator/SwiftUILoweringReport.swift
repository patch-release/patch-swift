// SPDX-License-Identifier: Apache-2.0

// LoweringReport.swift — the result of analyzing a SwiftUI body for lowerability.
//
// The headline measurement of Breakthrough #3 is "what % of a real view's
// nodes + modifiers lower cleanly to the ViewNode IR (run in WASM) vs fall back
// to native?" This type IS that measurement.

import ViewNodeIR

/// One classified element from the body (a view primitive/container or a
/// modifier). `lowered == false` means it degraded to a native-fallback.
public struct ClassifiedElement: Equatable, Sendable {
    public enum Category: String, Sendable { case node, modifier }
    public var category: Category
    /// What it was, syntactically (e.g. "Text", "VStack", ".font", ".onTapGesture").
    public var name: String
    public var lowered: Bool
    /// If not lowered, why (for the honest-limits section of the report).
    public var reason: String?

    public init(category: Category, name: String, lowered: Bool, reason: String? = nil) {
        self.category = category; self.name = name
        self.lowered = lowered; self.reason = reason
    }
}

public struct LoweringReport: Equatable, Sendable {
    public var viewName: String
    public var elements: [ClassifiedElement]

    public init(viewName: String, elements: [ClassifiedElement]) {
        self.viewName = viewName
        self.elements = elements
    }

    public var totalNodes: Int { elements.filter { $0.category == .node }.count }
    public var loweredNodes: Int { elements.filter { $0.category == .node && $0.lowered }.count }
    public var totalModifiers: Int { elements.filter { $0.category == .modifier }.count }
    public var loweredModifiers: Int { elements.filter { $0.category == .modifier && $0.lowered }.count }

    public var totalElements: Int { elements.count }
    public var loweredElements: Int { elements.filter { $0.lowered }.count }

    /// The headline number: fraction of body elements that run in WASM.
    public var coverage: Double {
        totalElements == 0 ? 0 : Double(loweredElements) / Double(totalElements)
    }
    public var nodeCoverage: Double {
        totalNodes == 0 ? 0 : Double(loweredNodes) / Double(totalNodes)
    }

    /// Container node names that carry no visible content of their own.
    static let containerNodeNames: Set<String> =
        ["VStack", "HStack", "ZStack", "Group", "ForEach"]

    /// Whether the body lowered ≥1 CONTENT node (a Text/Image/shape/control/etc. —
    /// anything that isn't a bare container). A view whose lowered tree is ONLY
    /// containers + opaque slots (a pure routing/layout shell like a root
    /// `ContentView` that just switches between child screens) is NOT worth
    /// auto-routing: there's nothing patchable to gain, and routing the root view
    /// would put a WASM call on every frame. Such views stay native.
    public var hasLoweredContentNode: Bool {
        elements.contains {
            $0.category == .node && $0.lowered
                && !LoweringReport.containerNodeNames.contains($0.name)
        }
    }

    /// Whether the body lowered ≥1 CONTAINER node (VStack/HStack/ZStack/Group/ForEach).
    /// A `@ViewBuilder`-child container (e.g. `struct Card<Content: View>: View`) whose
    /// body wraps the caller-supplied child in a container shell (VStack { content() })
    /// HAS genuinely OTA-patchable structure even though the content is an opaque native
    /// slot — the container's layout/spacing/arrangement CAN change OTA. This is what
    /// allows the chrome to ship while the child renders natively from the thunk slot.
    public var hasLoweredContainerNode: Bool {
        elements.contains {
            $0.category == .node && $0.lowered
                && LoweringReport.containerNodeNames.contains($0.name)
        }
    }

    /// Whether the body carries ANY GENUINELY-PATCHABLE lowered element worth
    /// auto-routing for — a content node (Text/Image/shape/control), a lowered
    /// MODIFIER (a styled container's `.padding`/`.cornerRadius`/`.background(token)`
    /// rides WASM, so editing it ships OTA), OR a lowered CONTAINER (a
    /// `@ViewBuilder`-child container like `Card<Content>` whose VStack/HStack chrome is
    /// itself the patchable element). This is LESS strict than `hasLoweredContentNode`,
    /// which ignored patchable modifiers and so wrongly kept a styled container
    /// (`SurfaceCard`/`BottomBar`/`SettingsSection` — a `content` slot wrapped in
    /// patchable styling) NATIVE. A PURE PASS-THROUGH (just an opaque slot, nothing
    /// lowered at all) still gains nothing and stays native (all three are false). The
    /// point is honesty: "auto-routed" must mean an edit to the body can actually SHIP.
    public var hasPatchableLoweredElement: Bool {
        hasLoweredContentNode || loweredModifiers > 0 || hasLoweredContainerNode
    }
    public var modifierCoverage: Double {
        totalModifiers == 0 ? 0 : Double(loweredModifiers) / Double(totalModifiers)
    }

    // MARK: - Interactive breakdown (Breakthrough #5)
    //
    // For an interactive view, separate the three concerns the deliverable asks
    // about: STRUCTURE (layout primitives/containers/modifiers), STATE-bound
    // CONTROLS (Toggle/Slider/Stepper/TextField — each a two-way binding), and
    // EVENT logic (taps/buttons → guest dispatch). All three now lower; this
    // reports the per-concern coverage so the "% of an interactive view in WASM"
    // is honest about which concern is which.

    static let interactiveControlNames: Set<String> =
        ["Toggle", "Slider", "Stepper", "TextField"]
    static let eventElementNames: Set<String> =
        ["Button", ".onTapGesture"]

    public var interactiveControlElements: [ClassifiedElement] {
        elements.filter { LoweringReport.interactiveControlNames.contains($0.name) }
    }
    public var eventElements: [ClassifiedElement] {
        elements.filter { LoweringReport.eventElementNames.contains($0.name) }
    }
    /// Has any state-bound control or event element? (Is this view interactive?)
    public var isInteractive: Bool {
        !interactiveControlElements.isEmpty || !eventElements.isEmpty
    }
    public var loweredInteractiveControls: Int {
        interactiveControlElements.filter { $0.lowered }.count
    }
    public var loweredEventElements: Int {
        eventElements.filter { $0.lowered }.count
    }

    /// The distinct reasons elements fell back to native (honest limits).
    public var fallbackReasons: [String: Int] {
        var counts: [String: Int] = [:]
        for e in elements where !e.lowered {
            let r = e.reason ?? "unsupported"
            counts[r, default: 0] += 1
        }
        return counts
    }

    public func summary() -> String {
        let pct = { (d: Double) in String(format: "%.0f%%", d * 100) }
        var lines: [String] = []
        lines.append("=== Lowering report: \(viewName) ===")
        lines.append("  elements:  \(loweredElements)/\(totalElements) lowered  (\(pct(coverage)) WASM)")
        lines.append("  nodes:     \(loweredNodes)/\(totalNodes) lowered  (\(pct(nodeCoverage)))")
        lines.append("  modifiers: \(loweredModifiers)/\(totalModifiers) lowered  (\(pct(modifierCoverage)))")
        if isInteractive {
            let nc = interactiveControlElements.count
            let ne = eventElements.count
            if nc > 0 {
                lines.append("  state controls: \(loweredInteractiveControls)/\(nc) lowered "
                    + "(Toggle/Slider/Stepper/TextField → guest binding)")
            }
            if ne > 0 {
                lines.append("  event logic:    \(loweredEventElements)/\(ne) lowered "
                    + "(Button/onTap → guest dispatch)")
            }
        }
        if !fallbackReasons.isEmpty {
            lines.append("  native fallbacks:")
            for (reason, count) in fallbackReasons.sorted(by: { $0.value > $1.value }) {
                lines.append("    - \(reason): \(count)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// Aggregate report across several views (the corpus-level headline).
public struct CorpusReport: Sendable {
    public var reports: [LoweringReport]
    public init(_ reports: [LoweringReport]) { self.reports = reports }

    public var totalElements: Int { reports.reduce(0) { $0 + $1.totalElements } }
    public var loweredElements: Int { reports.reduce(0) { $0 + $1.loweredElements } }
    public var coverage: Double {
        totalElements == 0 ? 0 : Double(loweredElements) / Double(totalElements)
    }

    public func summary() -> String {
        var lines = reports.map { $0.summary() }
        let pct = String(format: "%.1f%%", coverage * 100)
        lines.append("")
        lines.append("=== CORPUS TOTAL: \(loweredElements)/\(totalElements) elements lowered = \(pct) WASM ===")
        return lines.joined(separator: "\n\n")
    }
}
