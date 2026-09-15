// SPDX-License-Identifier: MIT

// RenderCapabilities.swift — "can THIS device render THIS tree faithfully?"
// =========================================================================
// PatchSDK's floor is iOS/tvOS 15, but the renderer reconstitutes SwiftUI constructs that
// only exist on newer OSes (`NavigationStack`, `Grid`, `.scrollDisabled`, `AnyShape`, …).
// Each is `#available`-guarded in `Render.swift`, and each guard's `else` branch used to
// silently DEGRADE (drop the modifier, flatten the container, approximate the style). A
// patched view must never render differently from what the developer shipped, so the host
// asks this file first: when the running OS lacks a construct the tree uses and the renderer
// has no FAITHFUL pre-OS rendition of it, the view renders its NATIVE body instead
// (`PatchedBodyHost` + `Patch.thunkBody`).
//
// The decision is a pure function of (tree, OS version) — the OS is injected, never read via
// `#available`, so iOS 15 / 16 / 17 decisions are unit-testable on any host. Every
// `PatchRenderFeature.availability` mirrors the EXACT `#available(...)` tuple of the renderer
// branch it describes (a platform missing from the tuple is always available, like `*`).
// `RenderCapabilitiesTests` pins the set of `#available` sites in `Render.swift` so a new
// branch can't be added without classifying it here.
//
// Constructs whose pre-OS branch IS faithful keep rendering (no feature listed):
//   * Text-leaf styling (`Text("x").bold()`, `.fontWeight`, `.kerning`, `.underline`, …) — the
//     renderer applies the real iOS 13+ `Text` methods before iOS 16 (`legacyTextChainPrefixLength`).
//   * Shapes (`.clipShape`, `.background(_:in:)`, `.overlay(_:in:)`, `.contentShape`, shape
//     leaves, trims, strokes) — concrete generic dispatch instead of the iOS 16 `AnyShape`.
//   * `.tint(Color)` (iOS 15 overload), eager `NavigationLink(destination:)`, `.coordinateSpace(name:)`,
//     `.pickerStyle(.menu/.inline)` (iOS 14 statics), `AppStore`/`SKStoreReviewController`.

import Foundation
import PatchViewIR

/// An Apple platform family, as the renderer's `#available` checks distinguish them.
public enum PatchPlatform: String, Sendable, Hashable, CaseIterable {
    case iOS, macOS, tvOS, watchOS, visionOS
    /// A non-Apple host (no SwiftUI renderer): nothing is ever gated.
    case other
}

/// A `major.minor.patch` OS version number.
public struct PatchVersionNumber: Sendable, Hashable, Comparable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int
    public init(_ major: Int, _ minor: Int = 0, _ patch: Int = 0) {
        self.major = major; self.minor = minor; self.patch = patch
    }
    /// Parses `"16"`, `"16.4"`, `"16.4.1"`; nil for anything else.
    public init?(parsing text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var nums: [Int] = []
        for p in parts {
            guard let n = Int(p), n >= 0 else { return nil }
            nums.append(n)
        }
        self.init(nums[0], nums.count > 1 ? nums[1] : 0, nums.count > 2 ? nums[2] : 0)
    }
    public static func < (a: Self, b: Self) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }
    public var description: String { patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)" }
}

/// The OS a render decision is made for: a platform plus its version.
public struct PatchOSVersion: Sendable, Hashable, CustomStringConvertible {
    public var platform: PatchPlatform
    public var version: PatchVersionNumber
    public init(_ platform: PatchPlatform, _ version: PatchVersionNumber) {
        self.platform = platform; self.version = version
    }
    public static func iOS(_ major: Int, _ minor: Int = 0) -> Self { .init(.iOS, .init(major, minor)) }
    public static func tvOS(_ major: Int, _ minor: Int = 0) -> Self { .init(.tvOS, .init(major, minor)) }
    public static func macOS(_ major: Int, _ minor: Int = 0) -> Self { .init(.macOS, .init(major, minor)) }
    public static func visionOS(_ major: Int, _ minor: Int = 0) -> Self { .init(.visionOS, .init(major, minor)) }
    public var description: String { "\(platform.rawValue) \(version)" }

    /// The device this process runs on, in the terms the renderer's `#available` checks use.
    public static let current: PatchOSVersion = {
        #if targetEnvironment(macCatalyst)
        // Under Mac Catalyst `ProcessInfo` reports the macOS version, but `#available(iOS …)`
        // checks the iOS-equivalent one. Probe exactly the iOS thresholds `PatchRenderFeature`
        // uses (pinned by a test), which is all a render decision needs.
        let v: PatchVersionNumber
        if #available(iOS 18, *) { v = .init(18) }
        else if #available(iOS 17, *) { v = .init(17) }
        else if #available(iOS 16.4, *) { v = .init(16, 4) }
        else if #available(iOS 16.1, *) { v = .init(16, 1) }
        else if #available(iOS 16, *) { v = .init(16) }
        else { v = .init(15) }
        return PatchOSVersion(.iOS, v)
        #else
        let pi = ProcessInfo.processInfo.operatingSystemVersion
        let v = PatchVersionNumber(pi.majorVersion, pi.minorVersion, pi.patchVersion)
        #if os(iOS)
        return PatchOSVersion(.iOS, v)
        #elseif os(tvOS)
        return PatchOSVersion(.tvOS, v)
        #elseif os(visionOS)
        return PatchOSVersion(.visionOS, v)
        #elseif os(watchOS)
        return PatchOSVersion(.watchOS, v)
        #elseif os(macOS)
        return PatchOSVersion(.macOS, v)
        #else
        return PatchOSVersion(.other, v)
        #endif
        #endif
    }()
}

/// The minimum OS version per platform at which something is available. A platform with no
/// entry is always available (the `*` of an `#available` check).
public struct PatchOSAvailability: Sendable, Hashable {
    public var minimums: [PatchPlatform: PatchVersionNumber]
    public init(_ minimums: [PatchPlatform: PatchVersionNumber]) { self.minimums = minimums }

    public init(iOS: PatchVersionNumber? = nil, macOS: PatchVersionNumber? = nil,
                tvOS: PatchVersionNumber? = nil, watchOS: PatchVersionNumber? = nil,
                visionOS: PatchVersionNumber? = nil) {
        var m: [PatchPlatform: PatchVersionNumber] = [:]
        m[.iOS] = iOS; m[.macOS] = macOS; m[.tvOS] = tvOS; m[.watchOS] = watchOS; m[.visionOS] = visionOS
        self.minimums = m
    }

    public func isAvailable(on os: PatchOSVersion) -> Bool {
        guard let min = minimums[os.platform] else { return true }
        return os.version >= min
    }

    /// The stricter of two availabilities (per platform, the later minimum).
    public func merged(with other: PatchOSAvailability) -> PatchOSAvailability {
        PatchOSAvailability(minimums.merging(other.minimums) { Swift.max($0, $1) })
    }

    // The renderer's recurring `#available` tuples.
    /// `#available(iOS 16, macOS 13, tvOS 16, watchOS 9, *)` (visionOS always).
    static let v16 = PatchOSAvailability(iOS: .init(16), macOS: .init(13), tvOS: .init(16), watchOS: .init(9))
    /// `#available(iOS 16.1, macOS 13, tvOS 16.1, watchOS 9.1, visionOS 1, *)`.
    static let v16_1 = PatchOSAvailability(iOS: .init(16, 1), macOS: .init(13), tvOS: .init(16, 1), watchOS: .init(9, 1))
    /// `#available(iOS 16.4, macOS 13.3, tvOS 16.4, watchOS 9.4, [visionOS 1,] *)`.
    static let v16_4 = PatchOSAvailability(iOS: .init(16, 4), macOS: .init(13, 3), tvOS: .init(16, 4), watchOS: .init(9, 4))
    /// `#available(iOS 17, macOS 14, tvOS 17, watchOS 10, visionOS 1, *)`.
    static let v17 = PatchOSAvailability(iOS: .init(17), macOS: .init(14), tvOS: .init(17), watchOS: .init(10), visionOS: .init(1))
    /// `#available(iOS 18, macOS 15, tvOS 18, watchOS 11, visionOS 2, *)`.
    static let v18 = PatchOSAvailability(iOS: .init(18), macOS: .init(15), tvOS: .init(18), watchOS: .init(11), visionOS: .init(2))
}

/// A renderer construct that needs a newer OS than the SDK floor AND has no faithful rendition
/// below it. The raw value names the SwiftUI API (it appears in the native-demote log).
public enum PatchRenderFeature: String, Sendable, Hashable, CaseIterable, Comparable {
    // Containers / leaves
    case symbolVariableValue = "Image(systemName:variableValue:)"
    case gauge = "Gauge"
    case shareLink = "ShareLink"
    case navigationStack = "NavigationStack"
    case navigationStackPath = "NavigationStack(path:)"
    case grid = "Grid"
    case viewThatFits = "ViewThatFits"
    case controlGroup = "ControlGroup"
    case labeledContent = "LabeledContent"
    case menuOnTVOS = "Menu (tvOS)"
    case sectionIsExpanded = "Section(isExpanded:)"
    case unevenRoundedRectangle = "UnevenRoundedRectangle"
    // View-level text styling OUTSIDE a Text leaf's leading Text-method run
    case viewBold = "View.bold()"
    case viewItalic = "View.italic()"
    case viewFontWeight = "View.fontWeight(_:)"
    case viewKerning = "View.kerning(_:)"
    case viewTracking = "View.tracking(_:)"
    case viewBaselineOffset = "View.baselineOffset(_:)"
    case viewUnderline = "View.underline(_:color:)"
    case viewStrikethrough = "View.strikethrough(_:color:)"
    case viewMonospaced = "View.monospaced()"
    case fontDesign = "View.fontDesign(_:)"
    case fontWidth = "View.fontWidth(_:)"
    // Styles
    case tintShapeStyle = "View.tint(_: ShapeStyle)"
    case foregroundStyleLayers = "View.foregroundStyle(_:_:[_:])"
    case quinaryStyle = "ShapeStyle.quinary"
    case semanticStyleIOS17 = "ShapeStyle.separator/.placeholder/.link"
    case shadowStyle = "ShapeStyle.shadow(_:)"
    // Layout / scrolling
    case containerRelativeFrame = "containerRelativeFrame(_:alignment:)"
    case scrollClipDisabled = "scrollClipDisabled(_:)"
    case scrollContentBackground = "scrollContentBackground(_:)"
    case scrollDisabled = "scrollDisabled(_:)"
    case scrollIndicators = "scrollIndicators(_:axes:)"
    case scrollTargetBehavior = "scrollTargetBehavior(_:)"
    case scrollTargetLayout = "scrollTargetLayout()"
    case scrollBounceBehavior = "scrollBounceBehavior(_:axes:)"
    case contentMargins = "contentMargins(_:_:for:)"
    case safeAreaPadding = "safeAreaPadding(_:)"
    case horizontalSafeAreaInset = "safeAreaInset(edge: HorizontalEdge)"
    case defaultScrollAnchor = "defaultScrollAnchor(_:)"
    case scrollDismissesKeyboard = "scrollDismissesKeyboard(_:)"
    case lineLimitReservesSpace = "lineLimit(_:reservesSpace:)"
    // Presentation / navigation
    case navigationDestinationIsPresented = "navigationDestination(isPresented:)"
    case presentationDetents = "presentationDetents(_:)"
    case presentationDragIndicator = "presentationDragIndicator(_:)"
    case presentationCornerRadius = "presentationCornerRadius(_:)"
    case presentationContentInteraction = "presentationContentInteraction(_:)"
    case presentationCompactAdaptation = "presentationCompactAdaptation(_:)"
    // Chrome / effects / gestures / input
    case magnifyGesture = "MagnifyGesture"
    case rotateGesture = "RotateGesture"
    case labelsVisibility = "labelsVisibility(_:)"
    case menuIndicator = "menuIndicator(_:)"
    case menuOrder = "menuOrder(_:)"
    case persistentSystemOverlays = "persistentSystemOverlays(_:)"
    case badgeProminence = "badgeProminence(_:)"
    case geometryGroup = "geometryGroup()"
    case invalidatableContent = "invalidatableContent()"
    case contentTransition = "contentTransition(_:)"
    case selectionDisabled = "selectionDisabled(_:)"
    case textScale = "textScale(_:)"
    case symbolEffectsRemoved = "symbolEffectsRemoved(_:)"
    case findDisabled = "findDisabled(_:)"
    case replaceDisabled = "replaceDisabled(_:)"
    case pushTransition = "AnyTransition.push(from:)"
    case springPresetAnimation = "Animation.bouncy/.smooth/.snappy"
    case redactionInvalidated = "RedactionReasons.invalidated"
    case accessibilityTraitsIOS17 = "AccessibilityTraits.isStaticText/.isToggle"
    // Built-in named control styles
    case borderedButtonStyleOnTVOS = "buttonStyle(.bordered/.borderedProminent) (tvOS)"
    case menuPickerStyleOnTVOS = "pickerStyle(.menu) (tvOS)"
    case navigationLinkPickerStyle = "pickerStyle(.navigationLink)"
    case buttonToggleStyleOnTVOS = "toggleStyle(.button) (tvOS)"
    case navigationControlGroupStyle = "controlGroupStyle(.navigation)"
    case menuControlGroupStyle = "controlGroupStyle(.menu/.compactMenu)"
    case paletteControlGroupStyle = "controlGroupStyle(.palette)"
    case circleButtonBorderShape = "buttonBorderShape(.circle)"
    case extraLargeControlSize = "controlSize(.extraLarge)"

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// Where this construct renders faithfully — the exact `#available` tuple of its renderer branch.
    public var availability: PatchOSAvailability {
        typealias A = PatchOSAvailability
        typealias V = PatchVersionNumber
        switch self {
        case .symbolVariableValue, .grid, .viewThatFits, .labeledContent,
             .viewBold, .viewItalic, .viewFontWeight, .viewKerning, .viewTracking,
             .viewBaselineOffset, .viewUnderline, .viewStrikethrough, .viewMonospaced,
             .fontWidth, .tintShapeStyle, .quinaryStyle, .shadowStyle,
             .scrollContentBackground, .scrollDisabled, .scrollIndicators,
             .lineLimitReservesSpace, .menuOrder, .persistentSystemOverlays,
             .contentTransition, .pushTransition:
            return A.v16
        case .gauge, .shareLink:
            return A(iOS: V(16), macOS: V(13), watchOS: V(9))          // tvOS: `#if os(tvOS)` degrade (platform-unavailable)
        case .navigationStack, .navigationStackPath, .navigationDestinationIsPresented:
            return A(iOS: V(16), macOS: V(13), tvOS: V(16))
        case .controlGroup, .presentationDetents, .presentationDragIndicator, .navigationControlGroupStyle:
            return A(iOS: V(16), macOS: V(13))
        case .menuOnTVOS, .borderedButtonStyleOnTVOS, .menuPickerStyleOnTVOS:
            return A(tvOS: V(17))
        case .buttonToggleStyleOnTVOS:
            return A(iOS: V(15), macOS: V(12), tvOS: V(17), watchOS: V(9))
        case .unevenRoundedRectangle, .scrollBounceBehavior, .presentationCornerRadius,
             .presentationContentInteraction, .presentationCompactAdaptation:
            return A.v16_4
        case .fontDesign:
            return A.v16_1
        case .menuIndicator:
            return A(iOS: V(16), macOS: V(13), tvOS: V(17), watchOS: V(9))
        case .scrollDismissesKeyboard:
            return A(iOS: V(16), tvOS: V(16), watchOS: V(9))
        case .findDisabled, .replaceDisabled:
            return A(iOS: V(16))
        case .navigationLinkPickerStyle:
            return A(iOS: V(16), tvOS: V(16), watchOS: V(9))
        case .menuControlGroupStyle:
            return A(iOS: V(16, 4), macOS: V(13, 3))
        case .sectionIsExpanded, .foregroundStyleLayers, .semanticStyleIOS17,
             .containerRelativeFrame, .scrollClipDisabled, .scrollTargetLayout, .contentMargins,
             .safeAreaPadding, .defaultScrollAnchor, .geometryGroup, .invalidatableContent,
             .selectionDisabled, .textScale, .symbolEffectsRemoved, .springPresetAnimation,
             .redactionInvalidated, .accessibilityTraitsIOS17, .circleButtonBorderShape:
            return A.v17
        case .scrollTargetBehavior:
            return A(iOS: V(17), macOS: V(14), tvOS: V(17))
        case .magnifyGesture, .rotateGesture, .horizontalSafeAreaInset, .badgeProminence,
             .paletteControlGroupStyle:
            return A(iOS: V(17), macOS: V(14))
        case .extraLargeControlSize:
            return A(iOS: V(17), macOS: V(14), watchOS: V(10))
        case .labelsVisibility:
            return A.v18
        }
    }
}

/// The capability check `PatchedBodyHost` runs before rendering a patched tree.
public enum PatchRenderCapabilities {

    /// Every `PatchRenderFeature` the tree rooted at `node` uses (child nodes, modifier content
    /// subtrees and Canvas text leaves included). OS-independent — cache it with the tree.
    public static func requiredFeatures(in node: ViewNode) -> Set<PatchRenderFeature> {
        var out = Set<PatchRenderFeature>()
        collect(node, into: &out)
        return out
    }

    /// The features in `features` the OS `os` can't render faithfully, sorted (stable for logs).
    public static func unsupportedFeatures(_ features: Set<PatchRenderFeature>,
                                           on os: PatchOSVersion) -> [PatchRenderFeature] {
        features.filter { !$0.availability.isAvailable(on: os) }.sorted()
    }

    /// The features of `node`'s tree that `os` can't render faithfully (empty = render it).
    public static func unsupportedFeatures(in node: ViewNode, on os: PatchOSVersion) -> [PatchRenderFeature] {
        unsupportedFeatures(requiredFeatures(in: node), on: os)
    }

    /// True when every construct in `node`'s tree renders faithfully on `os`.
    public static func canRenderFaithfully(_ node: ViewNode, on os: PatchOSVersion = .current) -> Bool {
        unsupportedFeatures(in: node, on: os).isEmpty
    }

    /// True when some construct the renderer knows could be unavailable on `os` (false on the
    /// newest OSes, where the check can be skipped entirely).
    public static func mayLackFeatures(on os: PatchOSVersion) -> Bool {
        PatchRenderFeature.allCases.contains { !$0.availability.isAvailable(on: os) }
    }

    // MARK: - Shared with the renderer

    /// The number of LEADING modifiers on a Text leaf (`.text`/`.styledText`/`.dateText`) that
    /// have an exact iOS 13–15 `Text` method (`Text.bold()`, `Text.fontWeight(_:)`, …) — the run
    /// a pre-iOS-16 device renders as a real `Text` chain. Zero for a non-Text node.
    static func legacyTextChainPrefixLength(_ node: ViewNode) -> Int {
        switch node.kind {
        case .text, .styledText, .dateText: break
        default: return 0
        }
        var n = 0
        for m in node.modifiers {
            switch m {
            case .font, .fontToken, .foregroundColor, .bold, .italic, .fontWeight,
                 .kerning, .tracking, .baselineOffset, .underline, .strikethrough, .monospacedDigit:
                n += 1
            default:
                return n
            }
        }
        return n
    }

    /// True for a text-styling modifier whose `View` form is iOS 16+ but whose `Text` form is
    /// iOS 13+ (faithful before iOS 16 only inside the Text-chain prefix).
    static func isTextOnlyBeforeIOS16(_ m: Modifier) -> Bool {
        switch m {
        case .bold, .italic, .fontWeight, .kerning, .tracking, .baselineOffset, .underline, .strikethrough:
            return true
        default:
            return false
        }
    }

    // MARK: - Tree walk

    private static func collect(_ n: ViewNode, into out: inout Set<PatchRenderFeature>) {
        kindFeatures(n.kind, into: &out)
        let textPrefix = legacyTextChainPrefixLength(n)
        for (i, m) in n.modifiers.enumerated() {
            modifierFeatures(m, inTextChainPrefix: i < textPrefix, into: &out)
            for child in m.contentNodes { collect(child, into: &out) }
        }
        for child in n.childNodes { collect(child, into: &out) }
    }

    private static func kindFeatures(_ kind: NodeKind, into out: inout Set<PatchRenderFeature>) {
        switch kind {
        case .symbolImage(_, let variableValue):
            if variableValue != nil { out.insert(.symbolVariableValue) }
        case .gauge: out.insert(.gauge)
        case .shareLink: out.insert(.shareLink)
        case .navigationStack: out.insert(.navigationStack)
        case .navigationStackPath: out.insert(.navigationStackPath)
        case .grid, .gridRow: out.insert(.grid)
        case .viewThatFits: out.insert(.viewThatFits)
        case .controlGroup: out.insert(.controlGroup)
        case .labeledContent: out.insert(.labeledContent)
        case .menu: out.insert(.menuOnTVOS)
        case .boundSection: out.insert(.sectionIsExpanded)
        case .shape(let k): shapeFeatures(k, into: &out)
        case .canvas(let ops):
            for op in ops {
                switch op {
                case .fillPath(_, let style), .strokePath(_, let style, _): styleFeatures(style, into: &out)
                case .drawText: break   // its Text leaves are `childNodes`
                }
            }
        default:
            break
        }
    }

    private static func shapeFeatures(_ k: ShapeKind, into out: inout Set<PatchRenderFeature>) {
        if case .unevenRoundedRectangle = k { out.insert(.unevenRoundedRectangle) }
    }

    private static func styleFeatures(_ s: IRShapeStyle, into out: inout Set<PatchRenderFeature>) {
        switch s {
        case .hierarchical(let level):
            if !(0...3).contains(level) { out.insert(.quinaryStyle) }
        case .semantic(let name):
            if ["separator", "placeholder", "link"].contains(name) { out.insert(.semanticStyleIOS17) }
        case .shadow:
            out.insert(.shadowStyle)
        case .color, .linearGradient, .radialGradient, .angularGradient, .material:
            break
        }
    }

    private static func transitionFeatures(_ t: IRTransition, into out: inout Set<PatchRenderFeature>) {
        switch t {
        case .push: out.insert(.pushTransition)
        case .combined(let ts): for t in ts { transitionFeatures(t, into: &out) }
        case .asymmetric(let i, let r):
            transitionFeatures(i, into: &out); transitionFeatures(r, into: &out)
        case .identity, .opacity, .scale, .slide, .move, .offset, .blurReplace:
            break
        }
    }

    private static func modifierFeatures(_ m: Modifier, inTextChainPrefix: Bool,
                                         into out: inout Set<PatchRenderFeature>) {
        func textStyling(_ f: PatchRenderFeature) { if !inTextChainPrefix { out.insert(f) } }
        switch m {
        // View-level text styling (faithful inside a Text leaf's leading Text-method run)
        case .bold: textStyling(.viewBold)
        case .italic: textStyling(.viewItalic)
        case .fontWeight: textStyling(.viewFontWeight)
        case .kerning: textStyling(.viewKerning)
        case .tracking: textStyling(.viewTracking)
        case .baselineOffset: textStyling(.viewBaselineOffset)
        case .underline: textStyling(.viewUnderline)
        case .strikethrough: textStyling(.viewStrikethrough)
        case .monospaced: out.insert(.viewMonospaced)
        case .fontDesign: out.insert(.fontDesign)
        case .fontWidth: out.insert(.fontWidth)

        // Shapes + styles
        case .clipShape(let k), .contentShape(let k, _):
            shapeFeatures(k, into: &out)
        case .backgroundStyle(let s, let k):
            styleFeatures(s, into: &out)
            if let k { shapeFeatures(k, into: &out) }
        case .overlayStyle(let s, let k):
            styleFeatures(s, into: &out); shapeFeatures(k, into: &out)
        case .tintStyle(let s):
            if case .color = s {} else { out.insert(.tintShapeStyle) }
            styleFeatures(s, into: &out)
        case .foregroundStyle(let layers):
            if layers.count > 1 { out.insert(.foregroundStyleLayers) }
            for s in layers { styleFeatures(s, into: &out) }
        case .fill(let s, _), .stroke(let s, _), .strokeBorder(let s, _), .border(let s, _):
            styleFeatures(s, into: &out)

        // Layout / scrolling
        case .containerRelativeFrame: out.insert(.containerRelativeFrame)
        case .scrollClipDisabled: out.insert(.scrollClipDisabled)
        case .scrollContentBackground: out.insert(.scrollContentBackground)
        case .scrollDisabled: out.insert(.scrollDisabled)
        case .scrollIndicators: out.insert(.scrollIndicators)
        case .scrollTargetBehavior: out.insert(.scrollTargetBehavior)
        case .scrollTargetLayout: out.insert(.scrollTargetLayout)
        case .scrollBounceBehavior: out.insert(.scrollBounceBehavior)
        case .contentMargins: out.insert(.contentMargins)
        case .safeAreaPadding: out.insert(.safeAreaPadding)
        case .safeAreaInset(let edge, _, _, _):
            if edge != "top" && edge != "bottom" { out.insert(.horizontalSafeAreaInset) }
        case .defaultScrollAnchor: out.insert(.defaultScrollAnchor)
        case .scrollDismissesKeyboard: out.insert(.scrollDismissesKeyboard)
        case .lineLimitReservesSpace(_, let reserves):
            // `lineLimit(n, reservesSpace: false)` IS `lineLimit(n)` — the fallback is exact.
            if reserves { out.insert(.lineLimitReservesSpace) }

        // Presentation / navigation
        case .navigationDestinationBool: out.insert(.navigationDestinationIsPresented)
        case .presentationDetents(let detents):
            if !detents.isEmpty { out.insert(.presentationDetents) }
        case .presentationDragIndicator: out.insert(.presentationDragIndicator)
        case .presentationCornerRadius: out.insert(.presentationCornerRadius)
        case .presentationContentInteraction: out.insert(.presentationContentInteraction)
        case .presentationCompactAdaptation: out.insert(.presentationCompactAdaptation)

        // Chrome / effects / gestures
        case .magnifyGesture: out.insert(.magnifyGesture)
        case .rotateGesture: out.insert(.rotateGesture)
        case .labelsVisibility: out.insert(.labelsVisibility)
        case .menuIndicator: out.insert(.menuIndicator)
        case .menuOrder: out.insert(.menuOrder)
        case .persistentSystemOverlays: out.insert(.persistentSystemOverlays)
        case .badgeProminence: out.insert(.badgeProminence)
        case .geometryGroup: out.insert(.geometryGroup)
        case .invalidatableContent(let enabled):
            // The renderer applies nothing for `false` on EVERY OS — nothing to lose.
            if enabled { out.insert(.invalidatableContent) }
        case .contentTransition: out.insert(.contentTransition)
        case .selectionDisabled: out.insert(.selectionDisabled)
        case .textScale: out.insert(.textScale)
        case .symbolEffectsRemoved: out.insert(.symbolEffectsRemoved)
        case .findDisabled: out.insert(.findDisabled)
        case .replaceDisabled: out.insert(.replaceDisabled)
        case .transition(let t): transitionFeatures(t, into: &out)
        case .animation(let a, _):
            if let curve = a?.curve, ["bouncy", "smooth", "snappy"].contains(curve) {
                out.insert(.springPresetAnimation)
            }
        case .redacted(let reason):
            if reason == "invalidated" { out.insert(.redactionInvalidated) }
        case .accessibilityAddTraits(let traits), .accessibilityRemoveTraits(let traits):
            let names = traits.split(separator: "+")
            if names.contains("isStaticText") || names.contains("isToggle") {
                out.insert(.accessibilityTraitsIOS17)
            }

        // Built-in named control styles
        case .buttonStyle(let style):
            if style == .bordered || style == .borderedProminent { out.insert(.borderedButtonStyleOnTVOS) }
        case .pickerStyle(let style):
            if style == "menu" { out.insert(.menuPickerStyleOnTVOS) }
            if style == "navigationLink" { out.insert(.navigationLinkPickerStyle) }
        case .toggleStyle(let style):
            if style == "button" { out.insert(.buttonToggleStyleOnTVOS) }
        case .controlGroupStyle(let style):
            switch style {
            case "navigation": out.insert(.navigationControlGroupStyle)
            case "menu", "compactMenu": out.insert(.menuControlGroupStyle)
            case "palette": out.insert(.paletteControlGroupStyle)
            default: break
            }
        case .buttonBorderShape(let shape):
            if shape == "circle" { out.insert(.circleButtonBorderShape) }
        case .controlSize(let size):
            if size == "extraLarge" { out.insert(.extraLargeControlSize) }

        default:
            // Every other modifier renders identically on every OS the SDK supports (no
            // `#available` branch, or one whose floor is at/below iOS 15 / tvOS 15 / macOS 14).
            break
        }
    }
}
