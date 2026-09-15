// SPDX-License-Identifier: MIT

import XCTest
import Foundation
@testable import PatchSDK
import PatchViewIR
#if canImport(SwiftUI)
import SwiftUI
@testable import PatchRender
@testable import PatchSwiftUI
#endif

/// The iOS 15 floor's safety net: `PatchRenderCapabilities` decides — as a pure function of
/// (tree, injected OS version) — whether a device can render a patched tree FAITHFULLY, and
/// `PatchedBodyHost` / `Patch.thunkBody` / the manifest `minOS` gate render the view's NATIVE
/// body when it can't. Decisions for iOS 15 / 16 / 17 / 18 are exercised on any host because
/// the OS is injected (never read via `#available`).
final class RenderCapabilitiesTests: XCTestCase {

    // MARK: - Helpers

    private func node(_ kind: NodeKind, _ mods: Modifier...) -> ViewNode { ViewNode(kind, modifiers: mods) }
    private var text: NodeKind { .text("Hi") }
    private var stack: NodeKind { .vstack(alignment: nil, spacing: nil, children: [ViewNode(.text("child"))]) }
    private func features(_ n: ViewNode) -> Set<PatchRenderFeature> { PatchRenderCapabilities.requiredFeatures(in: n) }

    // MARK: - Versions & availability

    func testVersionParsingAndOrdering() {
        XCTAssertEqual(PatchVersionNumber(parsing: "16"), PatchVersionNumber(16))
        XCTAssertEqual(PatchVersionNumber(parsing: "16.4"), PatchVersionNumber(16, 4))
        XCTAssertEqual(PatchVersionNumber(parsing: "16.4.1"), PatchVersionNumber(16, 4, 1))
        for bad in ["", "16.", "a", "16.x", "1.2.3.4", "-1"] {
            XCTAssertNil(PatchVersionNumber(parsing: bad), bad)
        }
        XCTAssertLessThan(PatchVersionNumber(15, 8), PatchVersionNumber(16))
        XCTAssertLessThan(PatchVersionNumber(16, 3, 9), PatchVersionNumber(16, 4))
        XCTAssertEqual(PatchVersionNumber(16, 4).description, "16.4")
        XCTAssertEqual(PatchOSVersion.iOS(15, 2).description, "iOS 15.2")
    }

    func testAvailabilityTreatsUnlistedPlatformsAsAvailable() {
        let a = PatchOSAvailability(iOS: .init(16), tvOS: .init(17))
        XCTAssertFalse(a.isAvailable(on: .iOS(15, 5)))
        XCTAssertTrue(a.isAvailable(on: .iOS(16)))
        XCTAssertFalse(a.isAvailable(on: .tvOS(16, 4)))
        XCTAssertTrue(a.isAvailable(on: .tvOS(17)))
        XCTAssertTrue(a.isAvailable(on: .macOS(14)), "macOS not in the tuple → like `*`")
        XCTAssertTrue(a.isAvailable(on: .visionOS(1)))
        XCTAssertTrue(a.isAvailable(on: PatchOSVersion(.other, .init(0))))
        XCTAssertEqual(a.merged(with: PatchOSAvailability(iOS: .init(17))).minimums[.iOS], PatchVersionNumber(17))
    }

    func testCurrentOSIsThisHost() {
        #if os(macOS)
        XCTAssertEqual(PatchOSVersion.current.platform, .macOS)
        XCTAssertGreaterThanOrEqual(PatchOSVersion.current.version, PatchVersionNumber(14))
        #elseif os(iOS)
        XCTAssertEqual(PatchOSVersion.current.platform, .iOS)
        #endif
    }

    /// Mac Catalyst derives the iOS-equivalent version by probing exactly the iOS thresholds the
    /// features use; a feature introduced at any other iOS version would be misjudged there.
    func testEveryIOSThresholdIsOneTheCatalystProbeLadderKnows() {
        let ladder: Set<PatchVersionNumber> = [.init(15), .init(16), .init(16, 1), .init(16, 4), .init(17), .init(18)]
        for f in PatchRenderFeature.allCases {
            if let v = f.availability.minimums[.iOS] {
                XCTAssertTrue(ladder.contains(v), "\(f) needs iOS \(v), not in the Catalyst probe ladder")
            }
        }
    }

    func testMayLackFeaturesOnlyOnOlderOSes() {
        XCTAssertTrue(PatchRenderCapabilities.mayLackFeatures(on: .iOS(15)))
        XCTAssertTrue(PatchRenderCapabilities.mayLackFeatures(on: .iOS(16, 4)))
        XCTAssertTrue(PatchRenderCapabilities.mayLackFeatures(on: .iOS(17, 5)), "labelsVisibility is iOS 18")
        XCTAssertFalse(PatchRenderCapabilities.mayLackFeatures(on: .iOS(18)))
        XCTAssertFalse(PatchRenderCapabilities.mayLackFeatures(on: .macOS(15)))
        XCTAssertTrue(PatchRenderCapabilities.mayLackFeatures(on: .tvOS(15)))
        XCTAssertFalse(PatchRenderCapabilities.mayLackFeatures(on: .visionOS(2)))
    }

    // MARK: - Detection: one representative tree per feature (exhaustive)

    private var featureSamples: [PatchRenderFeature: ViewNode] {
        let red = IRShapeStyle.color(.named("red"))
        return [
            .symbolVariableValue: node(.symbolImage(systemName: "wifi", variableValue: 0.5)),
            .gauge: node(.gauge(data: IRGaugeData(value: 0.3), label: [])),
            .shareLink: node(.shareLink(items: ["https://x.y"], label: [])),
            .navigationStack: node(.navigationStack(children: [])),
            .navigationStackPath: node(.navigationStackPath(path: [], root: [], destinations: [], event: EventID("e"))),
            .grid: node(.gridRow(alignment: nil, children: [])),
            .viewThatFits: node(.viewThatFits(axes: .both, children: [])),
            .controlGroup: node(.controlGroup(children: [])),
            .labeledContent: node(.labeledContent(label: [], content: [])),
            .menuOnTVOS: node(.menu(label: [], items: [])),
            .sectionIsExpanded: node(.boundSection(header: [], isExpanded: true, content: [], event: EventID("e"))),
            .unevenRoundedRectangle: node(stack, .clipShape(.unevenRoundedRectangle(
                topLeading: 1, topTrailing: 2, bottomLeading: 3, bottomTrailing: 4, style: .continuous))),
            .viewBold: node(stack, .bold),
            .viewItalic: node(stack, .italic),
            .viewFontWeight: node(stack, .fontWeight(.semibold)),
            .viewKerning: node(stack, .kerning(1)),
            .viewTracking: node(stack, .tracking(1)),
            .viewBaselineOffset: node(stack, .baselineOffset(1)),
            .viewUnderline: node(stack, .underline(active: true, color: nil)),
            .viewStrikethrough: node(stack, .strikethrough(active: true, color: nil)),
            .viewMonospaced: node(text, .monospaced),
            .fontDesign: node(text, .fontDesign(.rounded)),
            .fontWidth: node(text, .fontWidth("condensed")),
            .tintShapeStyle: node(stack, .tintStyle(.linearGradient(IRGradient(stops: []), startPoint: .top, endPoint: .bottom))),
            .foregroundStyleLayers: node(stack, .foregroundStyle([red, .hierarchical(1)])),
            .quinaryStyle: node(stack, .foregroundStyle([.hierarchical(4)])),
            .semanticStyleIOS17: node(stack, .backgroundStyle(.semantic("separator"), in: nil)),
            .shadowStyle: node(stack, .fill(.shadow(IRShadowStyle(radius: 2)), eoFill: false)),
            .containerRelativeFrame: node(stack, .containerRelativeFrame(axes: "horizontal", alignment: nil)),
            .scrollClipDisabled: node(stack, .scrollClipDisabled(true)),
            .scrollContentBackground: node(stack, .scrollContentBackground("hidden")),
            .scrollDisabled: node(stack, .scrollDisabled(true)),
            .scrollIndicators: node(stack, .scrollIndicators("hidden", axes: "vertical")),
            .scrollTargetBehavior: node(stack, .scrollTargetBehavior("paging")),
            .scrollTargetLayout: node(stack, .scrollTargetLayout(true)),
            .scrollBounceBehavior: node(stack, .scrollBounceBehavior("basedOnSize", axes: "vertical")),
            .contentMargins: node(stack, .contentMargins(edges: "all", length: 8, placement: "automatic")),
            .safeAreaPadding: node(stack, .safeAreaPadding(edges: "all", length: 8, insets: nil)),
            .horizontalSafeAreaInset: node(stack, .safeAreaInset(edge: "leading", alignment: nil, spacing: nil, content: [])),
            .defaultScrollAnchor: node(stack, .defaultScrollAnchor(.bottom)),
            .scrollDismissesKeyboard: node(stack, .scrollDismissesKeyboard("immediately")),
            .lineLimitReservesSpace: node(text, .lineLimitReservesSpace(limit: 2, reservesSpace: true)),
            .navigationDestinationIsPresented: node(stack, .navigationDestinationBool(
                presentedKey: "p", isPresented: false, destination: [], event: EventID("e"))),
            .presentationDetents: node(stack, .presentationDetents(["medium"])),
            .presentationDragIndicator: node(stack, .presentationDragIndicator("visible")),
            .presentationCornerRadius: node(stack, .presentationCornerRadius(12)),
            .presentationContentInteraction: node(stack, .presentationContentInteraction("scrolls")),
            .presentationCompactAdaptation: node(stack, .presentationCompactAdaptation("sheet")),
            .magnifyGesture: node(stack, .magnifyGesture(EventID("e"))),
            .rotateGesture: node(stack, .rotateGesture(EventID("e"))),
            .labelsVisibility: node(stack, .labelsVisibility("hidden")),
            .menuIndicator: node(stack, .menuIndicator("hidden")),
            .menuOrder: node(stack, .menuOrder("fixed")),
            .persistentSystemOverlays: node(stack, .persistentSystemOverlays("hidden")),
            .badgeProminence: node(stack, .badgeProminence("increased")),
            .geometryGroup: node(stack, .geometryGroup),
            .invalidatableContent: node(stack, .invalidatableContent(true)),
            .contentTransition: node(text, .contentTransition("numericText")),
            .selectionDisabled: node(stack, .selectionDisabled(true)),
            .textScale: node(text, .textScale("secondary")),
            .symbolEffectsRemoved: node(stack, .symbolEffectsRemoved(true)),
            .findDisabled: node(stack, .findDisabled(true)),
            .replaceDisabled: node(stack, .replaceDisabled(true)),
            .pushTransition: node(stack, .transition(.asymmetric(insertion: .opacity, removal: .push(edge: "leading")))),
            .springPresetAnimation: node(stack, .animation(IRAnimation(curve: "snappy"), valueKey: "k")),
            .redactionInvalidated: node(stack, .redacted(reason: "invalidated")),
            .accessibilityTraitsIOS17: node(stack, .accessibilityAddTraits("isButton+isToggle")),
            .borderedButtonStyleOnTVOS: node(stack, .buttonStyle(.borderedProminent)),
            .menuPickerStyleOnTVOS: node(stack, .pickerStyle("menu")),
            .navigationLinkPickerStyle: node(stack, .pickerStyle("navigationLink")),
            .buttonToggleStyleOnTVOS: node(stack, .toggleStyle("button")),
            .navigationControlGroupStyle: node(stack, .controlGroupStyle("navigation")),
            .menuControlGroupStyle: node(stack, .controlGroupStyle("compactMenu")),
            .paletteControlGroupStyle: node(stack, .controlGroupStyle("palette")),
            .circleButtonBorderShape: node(stack, .buttonBorderShape("circle")),
            .extraLargeControlSize: node(stack, .controlSize("extraLarge")),
        ]
    }

    func testEveryFeatureIsDetectedFromARepresentativeTree() {
        let samples = featureSamples
        XCTAssertEqual(Set(samples.keys), Set(PatchRenderFeature.allCases),
                       "every PatchRenderFeature needs a detection sample")
        for (feature, tree) in samples {
            XCTAssertTrue(features(tree).contains(feature), "\(feature.rawValue) not detected in \(tree)")
        }
    }

    /// Every feature is available on the newest OSes the SDK knows and unavailable somewhere
    /// at or above the floor (else it wouldn't need to be a feature).
    func testEveryFeatureIsGatedSomewhereAndAvailableOnNewestOSes() {
        let newest: [PatchOSVersion] = [.iOS(18), .macOS(15), .tvOS(18), .visionOS(2), .init(.watchOS, .init(11))]
        let floors: [PatchOSVersion] = [.iOS(15), .macOS(14), .tvOS(15), .visionOS(1), .init(.watchOS, .init(8))]
        for f in PatchRenderFeature.allCases {
            for os in newest { XCTAssertTrue(f.availability.isAvailable(on: os), "\(f) unavailable on \(os)") }
            XCTAssertTrue(floors.contains { !f.availability.isAvailable(on: $0) }, "\(f) is never gated at the floors")
        }
    }

    // MARK: - Decisions per OS

    func testIOS15DemotesIOS16ConstructsAndIOS16RendersThem() {
        let tree = node(.vstack(alignment: nil, spacing: nil, children: [
            node(.navigationStack(children: [node(.text("Home"))])),
            node(.text("x"), .padding(IREdgeInsets(top: 1))),
        ]), .scrollDisabled(true))
        XCTAssertEqual(PatchRenderCapabilities.unsupportedFeatures(in: tree, on: .iOS(15, 2)),
                       [.navigationStack, .scrollDisabled].sorted())
        XCTAssertTrue(PatchRenderCapabilities.canRenderFaithfully(tree, on: .iOS(16)))
        XCTAssertTrue(PatchRenderCapabilities.canRenderFaithfully(tree, on: .iOS(17, 5)))
        XCTAssertFalse(PatchRenderCapabilities.canRenderFaithfully(tree, on: .tvOS(15)))
        XCTAssertTrue(PatchRenderCapabilities.canRenderFaithfully(tree, on: .macOS(14)))
    }

    /// The previously SILENT iOS 16.x / 17 / 18 degrades now demote on the OS just below.
    func testPointReleaseAndIOS17BranchesDemoteOnTheOSJustBelow() {
        let presentation = node(stack, .presentationCornerRadius(20))            // 16.4
        XCTAssertFalse(PatchRenderCapabilities.canRenderFaithfully(presentation, on: .iOS(16, 3)))
        XCTAssertTrue(PatchRenderCapabilities.canRenderFaithfully(presentation, on: .iOS(16, 4)))

        let design = node(text, .fontDesign(.serif))                              // 16.1
        XCTAssertFalse(PatchRenderCapabilities.canRenderFaithfully(design, on: .iOS(16)))
        XCTAssertTrue(PatchRenderCapabilities.canRenderFaithfully(design, on: .iOS(16, 1)))

        let clip = node(stack, .scrollClipDisabled(true))                         // 17
        XCTAssertFalse(PatchRenderCapabilities.canRenderFaithfully(clip, on: .iOS(16, 7)))
        XCTAssertTrue(PatchRenderCapabilities.canRenderFaithfully(clip, on: .iOS(17)))

        let labels = node(stack, .labelsVisibility("hidden"))                     // 18
        XCTAssertFalse(PatchRenderCapabilities.canRenderFaithfully(labels, on: .iOS(17, 6)))
        XCTAssertTrue(PatchRenderCapabilities.canRenderFaithfully(labels, on: .iOS(18)))

        let menu = node(.menu(label: [], items: []))                              // tvOS 17 only
        XCTAssertTrue(PatchRenderCapabilities.canRenderFaithfully(menu, on: .iOS(15)))
        XCTAssertFalse(PatchRenderCapabilities.canRenderFaithfully(menu, on: .tvOS(16)))
    }

    // MARK: - Faithful pre-iOS-16 renditions are NOT gated

    func testTextLeafStylingRunIsFaithfulOnIOS15() {
        let styled = node(.text("Title"), .font(IRFont(style: .title)), .bold, .fontWeight(.heavy),
                          .foregroundColor(.named("red")), .italic, .kerning(1), .tracking(2),
                          .baselineOffset(3), .underline(active: true, color: .named("blue")),
                          .strikethrough(active: false, color: nil), .monospacedDigit, .padding(IREdgeInsets(top: 4)))
        XCTAssertEqual(PatchRenderCapabilities.legacyTextChainPrefixLength(styled), 11)
        XCTAssertTrue(PatchRenderCapabilities.canRenderFaithfully(styled, on: .iOS(15)))
        XCTAssertTrue(PatchRenderCapabilities.canRenderFaithfully(
            node(.styledText("x", verbatim: true, markdown: false, localized: false), .bold), on: .iOS(15)))
        XCTAssertTrue(PatchRenderCapabilities.canRenderFaithfully(
            node(.dateText(epoch: 0, style: .time), .italic), on: .iOS(15)))
    }

    func testTextStylingAfterAViewModifierOrOnANonTextNodeIsGated() {
        // `Text("x").padding().bold()` → `View.bold()` (iOS 16) — not a Text method call.
        XCTAssertEqual(PatchRenderCapabilities.unsupportedFeatures(
            in: node(.text("x"), .padding(IREdgeInsets(top: 1)), .bold), on: .iOS(15)), [.viewBold])
        XCTAssertEqual(PatchRenderCapabilities.unsupportedFeatures(
            in: node(.image(systemName: "star"), .fontWeight(.bold)), on: .iOS(15)), [.viewFontWeight])
        XCTAssertEqual(PatchRenderCapabilities.legacyTextChainPrefixLength(node(stack, .bold)), 0)
        // `Text.monospaced()` is iOS 16.4 — no iOS 15 Text rendition.
        XCTAssertEqual(PatchRenderCapabilities.unsupportedFeatures(in: node(text, .monospaced), on: .iOS(15)),
                       [.viewMonospaced])
    }

    func testShapesTintAndValueDependentModifiersAreFaithful() {
        let faithful: [ViewNode] = [
            node(.shape(.circle), .trim(from: 0, to: 0.5),
                 .stroke(.color(.named("red")), IRStrokeStyle(lineWidth: 4))),
            node(.shape(.roundedRectangle(cornerRadius: 8)), .fill(.color(.named("blue")), eoFill: false)),
            node(stack, .clipShape(.capsule), .contentShape(.rectangle, eoFill: false),
                 .backgroundStyle(.material(.thin), in: .roundedRectangle(cornerRadius: 4)),
                 .overlayStyle(.color(.named("red")), in: .circle)),
            node(stack, .tint(.named("red")), .tintStyle(.color(.named("green"))), .accentColor(.named("pink"))),
            node(stack, .foregroundStyle([.hierarchical(3)]), .foregroundStyle([.semantic("tint")])),
            node(stack, .lineLimitReservesSpace(limit: 2, reservesSpace: false), .invalidatableContent(false)),
            node(stack, .presentationDetents([]), .pickerStyle("inline"), .pickerStyle("menu"),
                 .buttonStyle(.bordered), .toggleStyle("button"), .safeAreaInset(edge: "bottom", alignment: nil,
                                                                                spacing: nil, content: [])),
            node(stack, .animation(IRAnimation(curve: "spring"), valueKey: "k"), .transition(.slide),
                 .redacted(reason: "placeholder"), .accessibilityAddTraits("isButton+isHeader"),
                 .coordinateSpaceNamed("s"), .listRowSeparator("hidden", edges: "all")),
            node(.navigationLink(destination: [], label: [])),
            node(.canvas(ops: [.fillPath(commands: [], style: .color(.named("red")))])),
        ]
        for tree in faithful {
            XCTAssertEqual(PatchRenderCapabilities.unsupportedFeatures(in: tree, on: .iOS(15)), [], "\(tree)")
        }
        // …but the tvOS-17 statics still gate on tvOS 15/16.
        XCTAssertEqual(PatchRenderCapabilities.unsupportedFeatures(in: faithful[6], on: .tvOS(16)),
                       [.borderedButtonStyleOnTVOS, .buttonToggleStyleOnTVOS, .menuPickerStyleOnTVOS].sorted())
    }

    // MARK: - The walk reaches every subtree the renderer renders

    func testFeaturesInsideModifierContentTabsCanvasAndDestinationsAreFound() {
        let deep = node(.tabView(tabs: [IRTab(tag: "a", tabItem: [], content: [
            node(stack,
                 .sheet(presentedKey: "s", isPresented: false, content: [node(stack, .scrollDisabled(true))], event: EventID("e")),
                 .toolbar(items: [IRToolbarItem(placement: "principal", content: [node(.gauge(data: IRGaugeData(value: 1), label: []))])]),
                 .overlayContent(alignment: nil, content: [node(.canvas(ops: [
                    .strokePath(commands: [], style: .semantic("link"), lineWidth: 1),
                    .drawText(text: [node(.text("t"), .padding(IREdgeInsets()), .italic)], x: 0, y: 0, anchor: "center")]))]))
        ])], style: .automatic))
        let nav = node(.navigationStackPath(path: [], root: [], destinations: [
            IRNavDestination(typeTag: "T", body: [node(stack, .contentMargins(edges: "all", length: 1, placement: "automatic"))])
        ], event: EventID("e")))
        XCTAssertEqual(features(deep), [.scrollDisabled, .gauge, .semanticStyleIOS17, .viewItalic])
        XCTAssertEqual(features(nav), [.navigationStackPath, .contentMargins])
    }

    // MARK: - Tripwire: every `#available` site in the renderer is classified

    /// `PatchRenderFeature` mirrors the renderer's `#available` branches one by one. Adding,
    /// removing or re-versioning a branch in `Render.swift` must come with a decision in
    /// `RenderCapabilities.swift` (a feature, or a documented faithful fallback) — then update
    /// this fingerprint.
    func testRendererAvailabilitySitesAreUnchangedSinceTheCapabilityAudit() throws {
        let render = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PatchRender/Render.swift")
        guard let source = try? String(contentsOf: render, encoding: .utf8) else {
            throw XCTSkip("Render.swift not readable from the test bundle location")
        }
        let regex = try NSRegularExpression(pattern: #"#(un)?available\([^)]*\)"#)
        let sites = regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).map {
            String(source[Range($0.range, in: source)!])
        }
        let histogram = Dictionary(sites.map { ($0, 1) }, uniquingKeysWith: +)
        XCTAssertEqual(sites.count, 113, "Render.swift's #available sites changed — audit PatchRenderFeature, then update. \(histogram)")
        XCTAssertEqual(histogram["#available(iOS 17, macOS 14, tvOS 17, watchOS 10, visionOS 1, *)"], 24)
        XCTAssertEqual(histogram["#available(iOS 18, macOS 15, tvOS 18, watchOS 11, visionOS 2, *)"], 1)
        XCTAssertEqual(histogram["#available(iOS 16.1, macOS 13, tvOS 16.1, watchOS 9.1, visionOS 1, *)"], 1)
    }

    // MARK: - Manifest `minOS` (engine-resolved `if #available` branches)

    func testManifestMinOSDecodesAndGates() throws {
        let json = """
        {"schemaVersion":12,"views":[
          {"type":"New","export":"view_body__New","dispatch":null,"thunkSafe":true,"minVersion":8,
           "minOS":{"iOS":"17.0","macOS":"14.0"}},
          {"type":"Old","export":"view_body__Old","dispatch":null,"thunkSafe":true,"minVersion":8}
        ]}
        """
        let manifest = try JSONDecoder().decode(PatchViewManifest.self, from: Data(json.utf8))
        let new = try XCTUnwrap(manifest.views.first { $0.type == "New" })
        let old = try XCTUnwrap(manifest.views.first { $0.type == "Old" })
        XCTAssertEqual(new.minOS, ["iOS": "17.0", "macOS": "14.0"])
        XCTAssertNil(old.minOS, "an older cli's manifest has no minOS → no extra floor")
        XCTAssertFalse(new.meetsMinimumOS(.iOS(16, 7)))
        XCTAssertTrue(new.meetsMinimumOS(.iOS(17)))
        XCTAssertTrue(new.meetsMinimumOS(.tvOS(15)), "a platform the entry doesn't name is not gated")
        XCTAssertTrue(old.meetsMinimumOS(.iOS(15)))
        let garbage = PatchViewManifest.Entry(type: "G", export: "e", dispatch: nil, thunkSafe: true,
                                              minOS: ["iOS": "seventeen"])
        XCTAssertFalse(garbage.meetsMinimumOS(.iOS(18)), "an unparseable floor for this platform fails closed")
    }

    #if canImport(SwiftUI)
    @MainActor
    func testRegistryRefusesEntriesBelowTheirMinOS() {
        let registry = PatchViewPatchRegistry()
        let savedOS = PatchViewPatchRegistry.runningOS
        defer { PatchViewPatchRegistry.runningOS = savedOS }
        registry.manifestJSONOverrideForTesting = {
            """
            {"schemaVersion":12,"views":[
              {"type":"Needs17","export":"view_body__Needs17","dispatch":null,"thunkSafe":true,"minVersion":8,
               "minOS":{"iOS":"17.0","macOS":"14.0","tvOS":"17.0"}},
              {"type":"Plain","export":"view_body__Plain","dispatch":null,"thunkSafe":true,"minVersion":8}
            ]}
            """
        }
        PatchViewPatchRegistry.runningOS = .iOS(15, 5)
        XCTAssertNil(registry.entryIfPatchable(typeName: "Needs17"), "iOS 15 must render the native body")
        XCTAssertNotNil(registry.entryIfPatchable(typeName: "Plain"))
    }

    @MainActor
    func testRegistryKeepsEntriesAtOrAboveTheirMinOS() {
        let registry = PatchViewPatchRegistry()
        let savedOS = PatchViewPatchRegistry.runningOS
        defer { PatchViewPatchRegistry.runningOS = savedOS }
        registry.manifestJSONOverrideForTesting = {
            """
            {"schemaVersion":12,"views":[
              {"type":"Needs17","export":"view_body__Needs17","dispatch":null,"thunkSafe":true,"minVersion":8,
               "minOS":{"iOS":"17.0"}}
            ]}
            """
        }
        PatchViewPatchRegistry.runningOS = .iOS(17, 2)
        XCTAssertNotNil(registry.entryIfPatchable(typeName: "Needs17"))
    }

    func testPreflightOnlyRunsWithoutObservationInvalidation() async {
        await MainActor.run {
            let savedOS = PatchViewPatchRegistry.runningOS
            defer { PatchViewPatchRegistry.runningOS = savedOS }
            for (os, expected) in [(PatchOSVersion.iOS(15), true), (.iOS(16, 7), true), (.iOS(17), false),
                                   (.tvOS(16), true), (.tvOS(17), false), (.macOS(14), false), (.visionOS(1), false)] {
                PatchViewPatchRegistry.runningOS = os
                XCTAssertEqual(PatchViewPatchRegistry.needsCapabilityPreflight, expected, "\(os)")
            }
        }
    }
    #endif
}

// MARK: - PatchedBodyHost / thunkBody demotes (no WASM: the render caches are primed)

#if canImport(SwiftUI)
@MainActor
final class RenderCapabilityDemoteTests: XCTestCase {

    private let typeName = "CapDemoView"
    private var export: String { "view_body__\(typeName)" }
    private var entry: PatchViewManifest.Entry {
        PatchViewManifest.Entry(type: typeName, export: export, dispatch: nil, thunkSafe: true, minVersion: 8)
    }
    /// Fresh registry + caches with this view installed; returns the teardown to `defer`.
    private func prepare() -> () -> Void {
        Patch.configure(.init(appKey: "test-render-capabilities", apiBaseURL: nil))
        let savedOS = PatchViewPatchRegistry.runningOS
        PatchedBodyRenderCache.shared.reset()
        PatchedBodyPreMergeCache.shared.reset()
        PatchedBodyStaticTemplateCache.shared.reset()
        PatchViewPatchRegistry.shared.resetForTesting()
        PatchViewPatchRegistry.shared.installEntriesForTesting([entry])
        return {
            PatchViewPatchRegistry.runningOS = savedOS
            PatchViewPatchRegistry.shared.resetForTesting()
            PatchedBodyRenderCache.shared.reset()
            PatchedBodyPreMergeCache.shared.reset()
        }
    }

    private let iOS16OnlyTree = ViewNode(.navigationStack(children: [ViewNode(.text("Home"))]),
                                         modifiers: [.scrollDisabled(true)])
    private let iOS15SafeTree = ViewNode(.vstack(alignment: nil, spacing: 4, children: [
        ViewNode(.text("Title"), modifiers: [.font(IRFont(style: .headline)), .bold]),
        ViewNode(.shape(.circle), modifiers: [.trim(from: 0, to: 0.25), .stroke(.color(.named("red")), IRStrokeStyle(lineWidth: 2))]),
    ]), modifiers: [.clipShape(.roundedRectangle(cornerRadius: 6))])

    /// Prime the pre-merge cache exactly as a first `PatchedBodyHost.body` eval would key it.
    private func primeHost(_ tree: ViewNode, props: String = "{}") {
        let cacheEntry = PatchedBodyCacheEntry(tree: tree, slotArgs: [:], idSets: PatchedBodyHost.collectAllIDs(tree))
        PatchedBodyPreMergeCache.shared.store(
            typeName: typeName, export: export, propsJSON: props, guestState: "", guestBaseline: "",
            epoch: Patch.shared.moduleEpoch, tokenJSON: "",
            value: .init(merged: props, effectiveGuestState: "", entry: cacheEntry, mergedObj: nil))
    }

    private func settleDeferredDemotes() async {
        for _ in 0..<5 { await Task.yield() }
    }

    func testCollectAllIDsCarriesTheRenderFeatures() {
        XCTAssertEqual(PatchedBodyHost.collectAllIDs(iOS16OnlyTree).renderFeatures, [.navigationStack, .scrollDisabled])
        XCTAssertEqual(PatchedBodyHost.collectAllIDs(iOS15SafeTree).renderFeatures, [])
    }

    func testHostDemotesATreeTheOSCannotRenderFaithfully() async {
        let cleanup = prepare(); defer { cleanup() }
        PatchViewPatchRegistry.runningOS = .iOS(15, 4)
        primeHost(iOS16OnlyTree)
        let host = PatchedBodyHost(typeName: typeName, entry: entry, propsJSON: "{}", writebacks: [])
        _ = host.body
        await settleDeferredDemotes()
        XCTAssertNil(PatchViewPatchRegistry.shared.entryIfPatchable(typeName: typeName),
                     "an iOS 16-only tree on iOS 15 must demote the view to its native body")
    }

    func testHostRendersTheSameTreeOnIOS16() async {
        let cleanup = prepare(); defer { cleanup() }
        PatchViewPatchRegistry.runningOS = .iOS(16)
        primeHost(iOS16OnlyTree)
        let host = PatchedBodyHost(typeName: typeName, entry: entry, propsJSON: "{}", writebacks: [])
        _ = host.body
        await settleDeferredDemotes()
        XCTAssertNotNil(PatchViewPatchRegistry.shared.entryIfPatchable(typeName: typeName),
                        "iOS 16 renders NavigationStack/.scrollDisabled — no demote")
    }

    func testHostRendersFaithfulPreIOS16RenditionsOnIOS15() async {
        let cleanup = prepare(); defer { cleanup() }
        PatchViewPatchRegistry.runningOS = .iOS(15)
        primeHost(iOS15SafeTree)
        let host = PatchedBodyHost(typeName: typeName, entry: entry, propsJSON: "{}", writebacks: [])
        _ = host.body
        await settleDeferredDemotes()
        XCTAssertNotNil(PatchViewPatchRegistry.shared.entryIfPatchable(typeName: typeName),
                        "Text.bold / concrete shapes render faithfully on iOS 15 — no demote")
    }

    /// Below iOS 17 there is no Observation invalidation, so `thunkBody` must return nil (native
    /// body) in the SAME evaluation rather than hand out a host that can only go blank.
    func testThunkBodyPreflightReturnsNativeOnIOS15() async {
        let cleanup = prepare(); defer { cleanup() }
        struct Instance {}
        PatchViewPatchRegistry.runningOS = .iOS(15, 2)
        let props = PatchInstanceInputs.extract(from: Instance(), typeName: typeName).json
        let merged = PatchFlatJSON.merge(base: props, override: "")
        PatchedBodyRenderCache.shared.store(
            typeName: typeName, export: export, input: merged, epoch: Patch.shared.moduleEpoch,
            payload: PatchedBodyCacheEntry(tree: iOS16OnlyTree, slotArgs: [:],
                                           idSets: PatchedBodyHost.collectAllIDs(iOS16OnlyTree)))
        XCTAssertNil(Patch.shared.thunkBody(typeName: typeName, instance: Instance()),
                     "the pre-flight must route the native body immediately")
        await settleDeferredDemotes()
        XCTAssertNil(PatchViewPatchRegistry.shared.entryIfPatchable(typeName: typeName), "and demote for the epoch")
    }

    func testThunkBodyPreflightRoutesAFaithfulTreeAndRunsOncePerEpoch() {
        let cleanup = prepare(); defer { cleanup() }
        struct Instance {}
        PatchViewPatchRegistry.runningOS = .iOS(15, 2)
        let props = PatchInstanceInputs.extract(from: Instance(), typeName: typeName).json
        let merged = PatchFlatJSON.merge(base: props, override: "")
        PatchedBodyRenderCache.shared.store(
            typeName: typeName, export: export, input: merged, epoch: Patch.shared.moduleEpoch,
            payload: PatchedBodyCacheEntry(tree: iOS15SafeTree, slotArgs: [:],
                                           idSets: PatchedBodyHost.collectAllIDs(iOS15SafeTree)))
        XCTAssertNotNil(Patch.shared.thunkBody(typeName: typeName, instance: Instance()))
        XCTAssertTrue(PatchViewPatchRegistry.shared.hasPassedCapabilityPreflight(typeName: typeName))
        // A later tree is the HOST's job (its own demote) — the pre-flight doesn't re-run.
        PatchedBodyRenderCache.shared.reset()
        XCTAssertNotNil(Patch.shared.thunkBody(typeName: typeName, instance: Instance()))
    }

    func testThunkBodySkipsPreflightOnIOS17() {
        let cleanup = prepare(); defer { cleanup() }
        struct Instance {}
        PatchViewPatchRegistry.runningOS = .iOS(17)
        // No cached tree and no module: a pre-flight would find nothing and pass, but it must not
        // even run (no capability marker recorded).
        XCTAssertNotNil(Patch.shared.thunkBody(typeName: typeName, instance: Instance()))
        XCTAssertFalse(PatchViewPatchRegistry.shared.hasPassedCapabilityPreflight(typeName: typeName))
    }
}

// MARK: - The pre-iOS-16 renditions render the SAME pixels as the iOS 16+ path

/// On this (macOS 14+) host both paths exist, so the pre-iOS-16 concrete-shape / Text-chain
/// renditions can be rendered side by side with today's `AnyShape` / `View`-modifier path.
@available(iOS 16, macOS 13, tvOS 16, *)
@MainActor
final class LegacyRenditionFidelityTests: XCTestCase {

    private func pixels(_ view: AnyView) throws -> [UInt8] {
        let renderer = ImageRenderer(content: view.frame(width: 64, height: 64).background(Color.white))
        renderer.scale = 2
        guard let cg = renderer.cgImage, let data = cg.dataProvider?.data else {
            throw XCTSkip("ImageRenderer produced no image on this host")
        }
        return [UInt8](data as Data)
    }

    private let renderer = Renderer(context: RenderContext(showOpaqueStubs: false))

    /// Equal pixels AND not a blank canvas (so an empty render can't pass vacuously).
    private func assertSamePixels(_ legacy: AnyView, _ modern: AnyView, _ message: String,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        let l = try pixels(legacy), m = try pixels(modern)
        XCTAssertNotEqual(l, try pixels(AnyView(Color.white)), "blank render: \(message)", file: file, line: line)
        XCTAssertEqual(l, m, message, file: file, line: line)
    }

    func testTrimmedStrokedShapeMatchesAnyShapePath() throws {
        for kind: NodeKind in [
            .shape(.circle), .shape(.capsule), .shape(.roundedRectangle(cornerRadius: 10)),
            .path(commands: [.move(x: 4, y: 4), .line(x: 60, y: 10), .curve(cp1x: 10, cp1y: 50, cp2x: 50, cp2y: 60, x: 8, y: 58)]),
        ] {
            let stroked = ViewNode(kind, modifiers: [
                .trim(from: 0.1, to: 0.8), .stroke(.color(.named("red")), IRStrokeStyle(lineWidth: 5, cap: "round")),
                .padding(IREdgeInsets(top: 3, leading: 3, bottom: 3, trailing: 3)),
            ])
            let trimmedFill = ViewNode(kind, modifiers: [.trim(from: 0, to: 0.6), .fill(.color(.named("blue")), eoFill: false)])
            for n in [stroked, trimmedFill] {
                let modern = try XCTUnwrap(renderer.strokedShapeViaAnyShape(n))
                let legacy = try XCTUnwrap(renderer.strokedShapeConcrete(n))
                try assertSamePixels(legacy, modern, "\(n)")
            }
        }
        // Same nil decisions: an untrimmed, unstroked shape and a non-shape take the normal path.
        for n in [ViewNode(.shape(.circle)), ViewNode(.text("x"), modifiers: [.stroke(.color(.named("red")), IRStrokeStyle())])] {
            XCTAssertNil(renderer.strokedShapeViaAnyShape(n))
            XCTAssertNil(renderer.strokedShapeConcrete(n))
        }
    }

    func testConcreteShapeModifiersMatchAnyShapePath() throws {
        let base = AnyView(LinearGradient(colors: [.orange, .purple], startPoint: .top, endPoint: .bottom))
        let style = renderer.renderShapeStyle(.color(.named("green")))
        for k: ShapeKind in [.circle, .capsule, .ellipse, .rectangle, .roundedRectangle(cornerRadius: 12),
                             .unevenRoundedRectangle(topLeading: 2, topTrailing: 20, bottomLeading: 8,
                                                     bottomTrailing: 14, style: .circular)] {
            try assertSamePixels(renderer.withConcreteShape(k, ConcreteShapeClip(view: base)),
                                 AnyView(base.clipShape(renderer.shapeValue(k))), "clipShape \(k)")
            try assertSamePixels(renderer.withConcreteShape(k, ConcreteShapeBackground(view: AnyView(Text("A")), style: style)),
                                 AnyView(Text("A").background(style, in: renderer.shapeValue(k))), "background \(k)")
            try assertSamePixels(renderer.withConcreteShape(k, ConcreteShapeOverlay(view: base, style: style)),
                                 AnyView(base.overlay(style, in: renderer.shapeValue(k))), "overlay \(k)")
            try assertSamePixels(renderer.withConcreteShape(k, ConcreteShapeLeaf()),
                                 AnyView(renderer.shape(k)), "leaf \(k)")
        }
    }

    func testLegacyTextChainMatchesViewModifierPath() throws {
        let nodes = [
            ViewNode(.text("Patch"), modifiers: [.font(IRFont(size: 20)), .bold]),
            ViewNode(.text("Patch"), modifiers: [.fontWeight(.black), .italic, .foregroundColor(.named("red"))]),
            ViewNode(.text("Patch"), modifiers: [.underline(active: true, color: .named("blue")), .kerning(2),
                                                 .padding(IREdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))]),
        ]
        for n in nodes {
            let legacy = try XCTUnwrap(renderer.legacyTextChainIfNeeded(n), "\(n)")
            try assertSamePixels(legacy, renderer.render(n), "\(n)")
        }
        XCTAssertNil(renderer.legacyTextChainIfNeeded(ViewNode(.text("x"), modifiers: [.font(IRFont(style: .body))])),
                     "no iOS-16-only modifier → the normal path")
        XCTAssertNil(renderer.legacyTextChainIfNeeded(ViewNode(.image(systemName: "star"), modifiers: [.bold])))
    }
}
#endif
