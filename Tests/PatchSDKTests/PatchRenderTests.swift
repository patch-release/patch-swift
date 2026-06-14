import XCTest
import PatchViewIR
#if canImport(SwiftUI)
import SwiftUI
@testable import PatchRender
#endif

/// Proves the PRODUCTIZED SwiftUI renderer (Breakthrough #3/#5) in the SDK: a
/// `ViewNode` tree reconstitutes to REAL SwiftUI, and an interactive control's
/// binding dispatches an event back into the (would-be) guest dispatch.
final class PatchRenderTests: XCTestCase {

    // MARK: - IR + schema (no SwiftUI needed)

    /// The IR round-trips through its JSON wire format (the boundary format the
    /// guest emits and the host decodes), and the schema-version gate works.
    func testIRWireRoundTripAndSchema() throws {
        let tree = N.vstack(spacing: 8, [
            N.text("Hello").fontSize(17, weight: .semibold).foregroundColor(named: "primary"),
            N.toggle("Notify", isOn: true, event: "flip"),
            N.button("Save", actionID: "save")
        ]).padding(16)

        // Stamp the current schema version and round-trip the emission envelope.
        let emission = BodyEmission(root: tree, computeCoverage: true,
                                    schemaVersion: PatchViewIRSchema.version)
        let bytes = try ViewNodeWire.encode(emission)
        let back = try ViewNodeWire.decode(bytes)
        XCTAssertEqual(back.root, tree, "ViewNode survives the JSON boundary intact")
        XCTAssertEqual(back.schemaVersion, PatchViewIRSchema.version)
        XCTAssertNoThrow(try PatchViewIRSchema.check(back.schemaVersion))

        // The Foundation-FREE embedded emitter produces the SAME bytes the host
        // JSONDecoder reads (this is what a tiny embedded guest uses).
        let embeddedBytes = EmbeddedJSON.encode(emission)
        let backEmbedded = try ViewNodeWire.decode(embeddedBytes)
        XCTAssertEqual(backEmbedded.root, tree)
        XCTAssertEqual(backEmbedded.schemaVersion, PatchViewIRSchema.version)
    }

    /// An unstamped (legacy) emission decodes fine and is treated as current.
    func testUnstampedEmissionTreatedAsCurrent() throws {
        let emission = BodyEmission(root: N.text("hi"), computeCoverage: false)
        XCTAssertNil(emission.schemaVersion)
        XCTAssertNoThrow(try PatchViewIRSchema.check(emission.schemaVersion))
    }

    /// A future guest schema the host can't decode is rejected with a Mismatch.
    func testFutureSchemaRejected() {
        let future = PatchViewIRSchema.version + 1
        XCTAssertFalse(PatchViewIRSchema.isSupported(future))
        XCTAssertThrowsError(try PatchViewIRSchema.check(future)) { err in
            guard let m = err as? PatchViewIRSchema.Mismatch else {
                return XCTFail("expected Mismatch, got \(err)")
            }
            XCTAssertEqual(m.guestVersion, future)
        }
    }

    // MARK: - NEW (v2 leaf-views/containers/shapes) wire round-trips
    //
    // Each new NodeKind/ShapeKind survives BOTH codecs intact: the Foundation
    // `JSONEncoder` (host path) AND the Foundation-free `EmbeddedJSON` emitter (the
    // tiny-guest path). Decoding `EmbeddedJSON.encode` through `ViewNodeWire.decode`
    // is the precise-shape check — a wrong hand-rolled shape (a mislabeled payload,
    // a bare-string no-payload case, a missing field) fails to decode or decodes to
    // a different tree, failing the equality assertion.

    /// The NEW leaf views round-trip through both codecs identically.
    func testNewLeafViewsWireRoundTrip() throws {
        let tree = N.vstack([
            N.styledText("raw", verbatim: true),
            N.styledText("**bold**", markdown: true),
            N.styledText("WELCOME", localized: true),
            N.dateText(epoch: 1_700_000_000, style: .relative),
            N.symbolImage(systemName: "wifi", variableValue: 0.5),
            N.symbolImage(systemName: "star"),               // nil variableValue
            N.bundleImage(name: "Logo"),
            N.asyncImage(url: "https://example.com/a.png", scale: 2),
            N.asyncImage(url: "https://example.com/b.png"), // nil scale
            N.progressView(value: 0.4, total: 1, label: [N.text("Loading")]),
            N.progressView(value: 3, total: 10),            // empty label
            N.gauge(value: 5, min: 0, max: 10, label: [N.text("L")]),
            N.link(destination: "https://example.com", label: [N.text("Home")]),
            N.shareLink(items: ["a", "b"], label: [N.text("Share")]),
            N.shareLink(items: ["x"]),                       // empty label
            N.secureField("Password", text: "hunter2", event: "pw"),
            N.textEditor(text: "draft", event: "draft"),
            N.labeledContent(label: [N.text("Name")], content: [N.text("Ada")]),
            N.menu(label: [N.text("More")], items: [N.button("One", actionID: "one")]),
            N.label(title: [N.text("T")], icon: [N.image(systemName: "star")]),
            N.contextMenu(content: [N.text("Tap")], items: [N.button("Copy", actionID: "copy")])
        ])
        try assertRoundTrips(tree)
    }

    /// The NEW containers round-trip through both codecs identically.
    func testNewContainersWireRoundTrip() throws {
        let tree = N.scrollView(axis: .vertical, [
            N.lazyVStack(alignment: .leading, spacing: 8, [N.text("a")]),
            N.lazyHStack(spacing: 4, [N.text("b")]),
            N.lazyVGrid(columns: [
                IRGridItem(size: .flexible(min: 10, max: .infinity), spacing: 6, alignment: .top),
                IRGridItem(size: .fixed(80)),
                IRGridItem(size: .adaptive(min: 40, max: .points(120)))
            ], spacing: 12, [N.text("c"), N.text("d")]),
            N.lazyHGrid(rows: [IRGridItem(size: .fixed(50))], [N.text("e")]),
            N.grid(alignment: .topLeading, horizontalSpacing: 8, verticalSpacing: 8, [
                N.gridRow(alignment: .center, [N.text("r1c1"), N.text("r1c2")])
            ]),
            N.groupBox(label: [N.text("Box")], [N.text("boxed")]),
            N.disclosureGroup(label: [N.text("Section")], [N.text("hidden")]),
            N.viewThatFits(axes: .horizontal, [N.text("wide"), N.text("narrow")]),
            N.controlGroup([N.button("X", actionID: "x")]),
            N.tabView(tabs: [
                IRTab(tag: "home", tabItem: [N.label(title: "Home", systemImage: "house")],
                      content: [N.text("Home screen")]),
                IRTab(tag: "settings", tabItem: [N.text("Settings")],
                      content: [N.text("Settings screen")])
            ], style: .page)
        ])
        try assertRoundTrips(tree)
    }

    /// The NEW shape nodes (path + the two ShapeKind cases) round-trip identically.
    func testNewShapesWireRoundTrip() throws {
        let tree = N.vstack([
            N.path([
                .move(x: 0, y: 0),
                .line(x: 10, y: 0),
                .quad(cpx: 15, cpy: 5, x: 10, y: 10),
                .curve(cp1x: 8, cp1y: 12, cp2x: 4, cp2y: 12, x: 0, y: 10),
                .addRect(x: 1, y: 1, width: 8, height: 8),
                .addRoundedRect(x: 2, y: 2, width: 6, height: 6, cornerRadius: 1.5),
                .closeSubpath
            ]),
            N.shape(.unevenRoundedRectangle(topLeading: 4, topTrailing: 8,
                                            bottomLeading: 0, bottomTrailing: 12, style: .continuous)),
            N.shape(.containerRelative)
        ])
        try assertRoundTrips(tree)
    }

    /// Round-trip a tree through BOTH the Foundation codec and the Foundation-free
    /// embedded emitter, asserting it survives each intact (and that the embedded
    /// bytes are host-decodable to the SAME tree — the JSON-shape correctness check).
    private func assertRoundTrips(_ tree: ViewNode, file: StaticString = #filePath,
                                  line: UInt = #line) throws {
        let emission = BodyEmission(root: tree, computeCoverage: false,
                                    schemaVersion: PatchViewIRSchema.version)
        // Foundation codec (host path).
        let back = try ViewNodeWire.decode(try ViewNodeWire.encode(emission))
        XCTAssertEqual(back.root, tree, "tree survives the Foundation JSON boundary", file: file, line: line)
        // Foundation-FREE embedded emitter → SAME bytes the host JSONDecoder reads.
        let backEmbedded = try ViewNodeWire.decode(EmbeddedJSON.encode(emission))
        XCTAssertEqual(backEmbedded.root, tree,
                       "tree survives the embedded JSON emitter (shape matches synthesized Codable)",
                       file: file, line: line)
    }

    // MARK: - Real SwiftUI rendering

    #if canImport(SwiftUI)
    /// Every node kind + modifier renders to a real `AnyView` without trapping.
    @MainActor
    func testRenderProducesSwiftUIForAllKinds() {
        let tree = N.vstack(alignment: .center, spacing: 8, [
            N.text("hello").fontSize(20, weight: .bold).foregroundColor(named: "red"),
            N.image(systemName: "star.fill").foregroundColor(named: "yellow"),
            N.spacer(minLength: 4), N.divider,
            N.color(.named("blue")).frame(width: 40, height: 40),
            N.shape(.roundedRectangle(cornerRadius: 8)).frame(height: 20),
            N.hstack(spacing: 4, [N.text("a"), N.text("b")]),
            N.zstack(alignment: .topLeading, [N.text("z")]),
            N.group([N.text("g1"), N.text("g2")]),
            N.forEach([N.text("1"), N.text("2")]),
            N.button("Tap", actionID: "act1").padding().background(named: "green"),
            N.toggle("Notifications", isOn: true, event: "n"),
            N.slider(value: 0.4, in: 0...1, event: "v"),
            N.stepper("Badge", value: 3, in: 0...9, event: "b"),
            N.textField("Name", text: "Ada", event: "name"),
            N.opaque(id: "custom1", label: "MapView")
        ]).padding(.all(12)).opacity(0.95)
        XCTAssertNotNil(render(tree))
    }

    /// IR v2: the new containers + navigation shell + Label render to real
    /// SwiftUI without trapping, and the structural describe-dump reflects them.
    @MainActor
    func testRendersIRv2ContainersAndNavigationShell() {
        let tree = N.navigationStack([
            N.scrollView(axis: .vertical, [
                N.form([
                    N.section(header: [N.text("Account")],
                              footer: [N.text("Affects all")],
                              [
                                  N.label(title: "Profile", systemImage: "person.crop.circle"),
                                  N.text("Signed in")
                              ]),
                    N.list([
                        N.text("Row 1"),
                        N.section([N.text("Nested row")])
                    ])
                ]),
                N.scrollView(axis: .horizontal, [
                    N.hstack([N.text("a"), N.text("b")])
                ])
            ])
        ]).navigationTitle("Settings")

        // Materializes to a real AnyView (no trap).
        XCTAssertNotNil(render(tree))

        // The structural dump shows every new construct (proof the tree is shaped
        // right — the renderer is a pure function of the tree).
        let d = tree.describe()
        XCTAssertTrue(d.contains("NavigationStack"), d)
        XCTAssertTrue(d.contains("ScrollView(axis:vertical)"), d)
        XCTAssertTrue(d.contains("ScrollView(axis:horizontal)"), d)
        XCTAssertTrue(d.contains("Form"), d)
        XCTAssertTrue(d.contains("Section(header:1,footer:1)"), d)
        XCTAssertTrue(d.contains("List"), d)
        // The generalized Label is title+icon subtrees: the convenience builder emits
        // a Text title + an SF-symbol Image icon (both recurse in the describe dump).
        XCTAssertTrue(d.contains("Label(title:1,icon:1)"), d)
        XCTAssertTrue(d.contains("Text(\"Profile\")"), d)
        XCTAssertTrue(d.contains("Image(systemName:\"person.crop.circle\")"), d)
        XCTAssertTrue(d.contains(".navTitle(\"Settings\")"), d)
    }

    /// IR v2 trees survive the JSON wire boundary (guest emit → host decode) intact,
    /// AND the Foundation-free embedded emitter produces the same bytes — so a
    /// shipped module's containers/navigation shell round-trip identically.
    func testIRv2ContainersWireRoundTrip() throws {
        let tree = N.navigationStack([
            N.list([
                N.section(header: [N.text("H")], footer: [N.text("F")],
                          [N.label(title: "Item", systemImage: "star")]),
                N.form([N.scrollView(axis: .horizontal, [N.text("x")])])
            ])
        ]).navigationTitle("Title")

        let emission = BodyEmission(root: tree, computeCoverage: true,
                                    schemaVersion: PatchViewIRSchema.version)
        // Foundation codec round-trip.
        let back = try ViewNodeWire.decode(try ViewNodeWire.encode(emission))
        XCTAssertEqual(back.root, tree, "IR v2 tree survives the JSON boundary intact")
        // Foundation-FREE embedded emitter produces host-decodable bytes that match.
        let backEmbedded = try ViewNodeWire.decode(EmbeddedJSON.encode(emission))
        XCTAssertEqual(backEmbedded.root, tree,
                       "the embedded (guest) emitter's bytes decode to the same IR v2 tree")
    }

    /// IR v2: a tree using the flexible frame, the new common modifiers, an RGBA
    /// color node, and ProgressView renders to real SwiftUI without trapping.
    @MainActor
    func testRenderIRv2FlexFrameModifiersAndProgress() {
        let tree = N.vstack(spacing: 8, [
            N.text("flex")
                .flexFrame(minWidth: .points(0), maxWidth: .infinity,
                           maxHeight: .infinity, alignment: .topLeading)
                .tint(.rgba(IRColor(r: 0.2, g: 0.4, b: 0.9)))
                .clipShape(.capsule)
                .disabled(true)
                .fixedSize(),
            N.color(.rgba(IRColor(r: 0.1, g: 0.2, b: 0.3, a: 0.5)))
                .frame(width: 30, height: 30)
                .clipShape(.roundedRectangle(cornerRadius: 6)),
            N.progressView,
            N.button("Go", actionID: "go").tint(.named("indigo"))
        ])
        XCTAssertNotNil(render(tree))
    }

    /// IR v2 nodes/modifiers survive the JSON boundary intact — through BOTH the
    /// Foundation codec AND the Foundation-free embedded emitter. This exercises
    /// `IRLength` (`.points`/`.infinity`), the new modifiers, and `.progressView`.
    func testIRv2WireRoundTrip() throws {
        let tree = N.vstack([
            N.progressView,
            N.text("a")
                .flexFrame(minWidth: .points(10), idealWidth: nil, maxWidth: .infinity,
                           minHeight: nil, idealHeight: .points(44), maxHeight: .infinity,
                           alignment: .center)
                .tint(.rgba(IRColor(r: 0.2, g: 0.4, b: 0.9, a: 1)))
                .clipShape(.circle)
                .disabled(false)
                .fixedSize(),
            N.color(.rgba(IRColor(r: 0, g: 0.5, b: 1, a: 0.25)))
        ])
        let emission = BodyEmission(root: tree, computeCoverage: false,
                                    schemaVersion: PatchViewIRSchema.version)

        // Foundation codec (host path).
        let back = try ViewNodeWire.decode(try ViewNodeWire.encode(emission))
        XCTAssertEqual(back.root, tree, "IR v2 tree survives the Foundation JSON boundary")

        // Foundation-FREE embedded emitter (tiny-guest path) → SAME bytes the host
        // JSONDecoder reads. This is the precise-shape check for IRLength + the new
        // cases (a wrong shape — e.g. a bare "infinity" string — would fail here).
        let backEmbedded = try ViewNodeWire.decode(EmbeddedJSON.encode(emission))
        XCTAssertEqual(backEmbedded.root, tree, "IR v2 tree survives the embedded JSON emitter")
    }

    /// An interactive control's binding fires the Dispatcher with the event + new
    /// value — the host end of the WASM dispatch loop. THIS is "a dispatched event
    /// updates it" at the renderer layer.
    @MainActor
    func testDispatchedEventFlowsThroughRenderer() {
        var captured: [(String, IRValue)] = []
        let dispatcher = Dispatcher { e, v in captured.append((e.id, v)) }
        let ctx = RenderContext(dispatcher: dispatcher)

        _ = render(N.toggle("x", isOn: false, event: "flip"), context: ctx)
        // Simulate the Toggle's binding firing (what SwiftUI does on a tap).
        dispatcher.send(EventID("flip"), .bool(true))
        dispatcher.send(EventID("tap"), .none)

        XCTAssertEqual(captured.count, 2)
        XCTAssertEqual(captured[0].0, "flip"); XCTAssertEqual(captured[0].1, .bool(true))
        XCTAssertEqual(captured[1].1, .none)
    }

    // MARK: - IR v2: the MODIFIER-surface + IRShapeStyle expansion

    /// A tree exercising the full styling/layout/transform/text/control/gesture/
    /// lifecycle/animation modifier surface round-trips through BOTH the Foundation
    /// codec AND the Foundation-free embedded emitter — the precise-shape proof that
    /// every new `emitModifier` arm + supporting-type emitter matches synthesized
    /// Codable. A wrong JSON shape (esp. for IRShapeStyle/gradients) fails HERE.
    func testIRModifierSurfaceWireRoundTrip() throws {
        let grad = IRGradient(stops: [
            IRGradientStop(color: .named("red"), location: 0),
            IRGradientStop(color: .rgba(IRColor(r: 0, g: 0.2, b: 0.9, a: 1)), location: 1),
        ])
        let tree = N.vstack(spacing: 8, [
            // Styling — every IRShapeStyle case
            N.text("a").foregroundStyle([.color(.named("primary")), .color(.named("secondary"))]),
            N.shape(.rectangle).fill(.linearGradient(grad, startPoint: .top, endPoint: .bottom)),
            N.shape(.circle).fill(.radialGradient(grad, center: .center, startRadius: 0, endRadius: 40)),
            N.shape(.capsule).fill(.angularGradient(grad, center: .center, startAngle: 0, endAngle: 360)),
            N.text("m").background(.material(.ultraThin), in: .roundedRectangle(cornerRadius: 8)),
            N.text("h").foregroundStyle(.hierarchical(2)),
            N.text("sem").foregroundStyle(.semantic("tint")),
            N.text("sh").foregroundStyle(.shadow(IRShadowStyle(color: .named("black"), radius: 3, x: 1, y: 2))),
            N.shape(.rectangle)
                .stroke(.color(.named("blue")), IRStrokeStyle(lineWidth: 2, cap: "round", join: "bevel",
                                                              miterLimit: 4, dash: [4, 2], dashPhase: 1))
                .strokeBorder(.color(.named("green")), IRStrokeStyle(lineWidth: 1))
                .border(.color(.named("gray")), width: 2),
            N.text("bg").background(alignment: .topLeading, [N.color(.named("yellow"))]),
            N.text("ov").overlay(alignment: .bottom, [N.text("x")]).overlay(.color(.named("red")), in: .circle),
            N.text("mask").mask(alignment: .center, [N.shape(.circle)]),
            N.text("shadow").shadow(color: .named("black"), radius: 4, x: 0, y: 2),
            N.text("tint").tint(.linearGradient(grad, startPoint: .leading, endPoint: .trailing)),
            // Layout
            N.text("l").offset(x: 3, y: -4).position(x: 10, y: 20)
                .aspectRatio(1.5, contentMode: .fit).scaledToFit().scaledToFill()
                .clipped(antialiased: true).fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2).zIndex(3)
                .ignoresSafeArea(regions: "container", edges: "top+bottom")
                .containerRelativeFrame(axes: "horizontal", alignment: .center),
            N.text("sai").safeAreaInset(edge: "bottom", alignment: .center, spacing: 4, [N.text("inset")]),
            // Transforms / effects
            N.text("t").rotationEffect(degrees: 45, anchor: .topLeading)
                .rotation3DEffect(degrees: 30, x: 1, y: 0, z: 0, anchor: .center, anchorZ: 0, perspective: 1)
                .scaleEffect(x: 1.2, y: 0.8, anchor: .bottomTrailing)
                .blur(radius: 2, opaque: true).brightness(0.1).contrast(1.2)
                .saturation(0.5).grayscale(0.3).hueRotation(degrees: 90).colorInvert()
                .blendMode(.multiply),
            // Text styling
            N.text("ts").fontWeight(.bold).fontDesign(.rounded)
                .underline(true, color: .named("red")).strikethrough(false, color: nil)
                .kerning(1).tracking(2).baselineOffset(3).lineSpacing(4)
                .textCase("uppercase").minimumScaleFactor(0.5).truncationMode("middle")
                .monospaced().monospacedDigit().redacted(reason: "placeholder").unredacted()
                .symbolRenderingMode("hierarchical").symbolVariant("fill").imageScale("large")
                .dynamicTypeSize("xLarge"),
            // Control config
            N.button("b", actionID: "b").buttonStyle(.borderedProminent).buttonBorderShape("capsule")
                .controlSize("large"),
            N.list([N.text("row")]).listStyle(.insetGrouped),
            N.textField("p", text: "", event: "tf")
                .keyboardType("emailAddress").textContentType("emailAddress")
                .autocorrectionDisabled(true).textInputAutocapitalization("never")
                .submitLabel("go"),
            N.text("scheme").preferredColorScheme("dark").accentColor(.named("indigo")),
            // Gestures
            N.text("g").onLongPressGesture(minimumDuration: 0.4, event: "lp")
                .dragGesture(minDistance: 5, onChanged: "dc", onEnded: "de")
                .magnifyGesture(event: "mg").rotateGesture(event: "rg"),
            // Lifecycle
            N.text("lc").onAppear(event: "ap").onDisappear(event: "dis")
                .onChange(valueKey: "count", event: "chg").task(event: "tk", id: "load")
                .onSubmit(event: "sub").onHover(event: "hv")
                .sensoryFeedback(kind: "impact", triggerKey: "count"),
            // Animation
            N.text("an").animation(IRAnimation(curve: "easeInOut", duration: 0.3), valueKey: "count")
                .transition(.asymmetric(insertion: .scale(scale: 0.5, anchor: .center),
                                        removal: .combined([.opacity, .move(edge: "bottom")]))),
        ])

        let emission = BodyEmission(root: tree, computeCoverage: false,
                                    schemaVersion: PatchViewIRSchema.version)
        // Foundation codec (host path).
        let back = try ViewNodeWire.decode(try ViewNodeWire.encode(emission))
        XCTAssertEqual(back.root, tree, "IR modifier surface survives the Foundation JSON boundary")
        // Foundation-FREE embedded emitter (tiny-guest path) → SAME bytes the host
        // JSONDecoder reads. This is the precise-shape check.
        let backEmbedded = try ViewNodeWire.decode(EmbeddedJSON.encode(emission))
        XCTAssertEqual(backEmbedded.root, tree, "IR modifier surface survives the embedded JSON emitter")
    }

    /// `IRValue.point` (gestures) and the `IRUnitPoint.xy` arbitrary point both
    /// round-trip through both codecs — the new value-payload shapes.
    func testIRValuePointAndUnitPointXYRoundTrip() throws {
        let tree = N.text("p")
            .scaleEffect(x: 1, y: 1, anchor: .xy(x: 0.25, y: 0.75))
            .background(.radialGradient(IRGradient(stops: [IRGradientStop(color: .named("red"), location: 0)]),
                                        center: .xy(x: 0.1, y: 0.2), startRadius: 0, endRadius: 10))
        let emission = BodyEmission(root: tree, computeCoverage: false, schemaVersion: PatchViewIRSchema.version)
        XCTAssertEqual(try ViewNodeWire.decode(try ViewNodeWire.encode(emission)).root, tree)
        XCTAssertEqual(try ViewNodeWire.decode(EmbeddedJSON.encode(emission)).root, tree)

        // IRValue.point Codable (carried in dispatch events).
        let pt = IRValue.point(3.5, -2.0)
        let data = try JSONEncoder().encode(pt)
        XCTAssertEqual(try JSONDecoder().decode(IRValue.self, from: data), pt)
    }

    /// A v1 (legacy) tree still decodes + renders under the v2 host — the additive
    /// compatibility guarantee (minSupportedVersion stays 1).
    func testLegacyV1TreeStillRoundTrips() throws {
        let tree = N.vstack(spacing: 8, [
            N.text("Hi").font(style: .title).bold().foregroundColor(named: "primary"),
            N.toggle("On", isOn: true, event: "t"),
        ]).padding(12).cornerRadius(8)
        let emission = BodyEmission(root: tree, computeCoverage: false, schemaVersion: 1)
        let back = try ViewNodeWire.decode(EmbeddedJSON.encode(emission))
        XCTAssertEqual(back.root, tree)
        XCTAssertNoThrow(try PatchViewIRSchema.check(1))   // v1 still supported by v2 host
    }

    #if canImport(SwiftUI)
    /// Every new modifier renders to a real `AnyView` without trapping (the SDK
    /// `apply` arms + `renderShapeStyle`). Covers the full surface in one tree.
    @MainActor
    func testRenderIRModifierSurfaceProducesSwiftUI() {
        let grad = IRGradient(stops: [
            IRGradientStop(color: .named("red"), location: 0),
            IRGradientStop(color: .named("blue"), location: 1),
        ])
        let tree = N.vstack([
            N.text("a")
                .foregroundStyle([.color(.named("primary")), .color(.named("secondary"))])
                .background(.material(.thin), in: .roundedRectangle(cornerRadius: 6))
                .tint(.linearGradient(grad, startPoint: .top, endPoint: .bottom))
                .shadow(color: .named("black"), radius: 3, x: 0, y: 1)
                .offset(x: 2, y: 2).rotationEffect(degrees: 10, anchor: .center)
                .scaleEffect(x: 1.1, y: 1.1, anchor: nil).blur(radius: 1, opaque: false)
                .brightness(0.05).saturation(0.9).hueRotation(degrees: 30).colorInvert()
                .blendMode(.overlay).fontWeight(.semibold)
                .underline(true, color: .named("blue")).kerning(0.5).lineSpacing(2)
                .textCase("lowercase").minimumScaleFactor(0.7).monospacedDigit()
                .symbolRenderingMode("palette").imageScale("medium"),
            N.shape(.rectangle)
                .fill(.radialGradient(grad, center: .center, startRadius: 0, endRadius: 50))
                .stroke(.color(.named("green")), IRStrokeStyle(lineWidth: 2, dash: [3, 3]))
                .border(.color(.named("gray")), width: 1)
                .overlay(alignment: .center, [N.text("o")])
                .mask(alignment: .center, [N.shape(.circle)])
                .aspectRatio(1.0, contentMode: .fit).clipped(antialiased: true)
                .zIndex(1).layoutPriority(1),
            N.button("Go", actionID: "go")
                .buttonStyle(.bordered).buttonBorderShape("capsule").controlSize("large"),
            N.list([N.text("r")]).listStyle(.plain),
            N.text("g")
                .onLongPressGesture(minimumDuration: 0.3, event: "lp")
                .dragGesture(minDistance: 8, onChanged: "dc", onEnded: "de")
                .onAppear(event: "ap").onDisappear(event: "dis").task(event: "tk")
                .onSubmit(event: "sub")
                .transition(.combined([.opacity, .scale(scale: 0.5, anchor: .center)]))
                .animation(IRAnimation(curve: "spring", response: 0.4, dampingFraction: 0.8), valueKey: "x"),
        ])
        XCTAssertNotNil(render(tree))
    }

    /// A dispatched DRAG ships `value.translation` as `IRValue.point`, and a
    /// long-press / hover fire their events — the new gesture bridges at the
    /// renderer layer.
    @MainActor
    func testNewGesturesDispatchThroughRenderer() {
        var captured: [(String, IRValue)] = []
        let dispatcher = Dispatcher { e, v in captured.append((e.id, v)) }
        _ = render(N.text("g").dragGesture(minDistance: 5, onChanged: "dc", onEnded: "de"),
                   context: RenderContext(dispatcher: dispatcher))
        // Simulate the gesture firing what SwiftUI would on drag.
        dispatcher.send(EventID("dc"), .point(12, -5))
        dispatcher.send(EventID("de"), .point(20, 0))
        XCTAssertEqual(captured.count, 2)
        XCTAssertEqual(captured[0].1, .point(12, -5))
        XCTAssertEqual(captured[1].1, .point(20, 0))
    }

    /// `renderShapeStyle` resolves every `IRShapeStyle` case to a real
    /// `AnyShapeStyle` without trapping (gradients, material, hierarchical,
    /// semantic, shadow).
    @MainActor
    func testRenderShapeStyleResolvesEveryCase() {
        let r = Renderer(context: RenderContext())
        let grad = IRGradient(stops: [IRGradientStop(color: .named("red"), location: 0),
                                      IRGradientStop(color: .named("blue"), location: 1)])
        let styles: [IRShapeStyle] = [
            .color(.named("red")), .color(.rgba(IRColor(r: 0.1, g: 0.2, b: 0.3, a: 0.5))),
            .linearGradient(grad, startPoint: .top, endPoint: .bottom),
            .radialGradient(grad, center: .center, startRadius: 0, endRadius: 30),
            .angularGradient(grad, center: .center, startAngle: 0, endAngle: 360),
            .material(.ultraThin), .material(.bar),
            .hierarchical(0), .hierarchical(1), .hierarchical(2), .hierarchical(3), .hierarchical(4),
            .semantic("tint"), .semantic("foreground"), .semantic("separator"),
            .semantic("placeholder"), .semantic("link"),
            .shadow(IRShadowStyle(color: .named("black"), radius: 3, x: 1, y: 1)),
        ]
        for s in styles { _ = r.renderShapeStyle(s) }   // must not trap
        XCTAssertEqual(styles.count, 18)
    }
    #endif

    /// `PatchView` drives the closure-based TEA loop: the reduce closure runs on a
    /// dispatched event and the new state is produced. (We exercise the reduce
    /// wiring directly; the SwiftUI @State re-render is covered by the live-module
    /// test in PatchSwiftUI.)
    @MainActor
    func testPatchViewReduceWiring() {
        var reduced: [(String, EventID, IRValue)] = []
        let view = PatchView(
            initialState: "{\"on\":false}",
            treeProvider: { _ in N.toggle("x", isOn: false, event: "flip") },
            reduce: { state, event, value in
                reduced.append((state, event, value))
                return "{\"on\":true}"
            })
        // Building the body installs a dispatcher bound to the reduce closure.
        _ = view.body
        XCTAssertNotNil(view.treeProvider("{}"))
        XCTAssertNotNil(view.reduce)
        // Drive the reduce directly (what the dispatcher does on a control change).
        _ = view.reduce?("{\"on\":false}", EventID("flip"), .bool(true))
        XCTAssertEqual(reduced.count, 1)
        XCTAssertEqual(reduced[0].1.id, "flip")
        XCTAssertEqual(reduced[0].2, .bool(true))
    }

    /// The NEW leaf views render to a real `AnyView` without trapping, and the
    /// structural describe-dump reflects them.
    @MainActor
    func testRendersNewLeafViews() {
        let tree = N.vstack([
            N.styledText("**bold**", markdown: true),
            N.styledText("WELCOME", localized: true),
            N.styledText("raw", verbatim: true),
            N.dateText(epoch: 1_700_000_000, style: .timer),
            N.symbolImage(systemName: "wifi", variableValue: 0.5),
            N.bundleImage(name: "Logo"),
            N.asyncImage(url: "https://example.com/a.png", scale: 2),
            N.progressView(value: 0.4, total: 1, label: [N.text("Loading")]),
            N.gauge(value: 5, min: 0, max: 10, label: [N.text("L")]),
            N.link(destination: "https://example.com", label: [N.text("Home")]),
            N.shareLink(items: ["share me"], label: [N.text("Share")]),
            N.secureField("Password", text: "x", event: "pw"),
            N.textEditor(text: "draft", event: "d"),
            N.labeledContent(label: [N.text("Name")], content: [N.text("Ada")]),
            N.menu(label: [N.text("More")], items: [N.button("One", actionID: "one")]),
            N.label(title: [N.text("T")], icon: [N.image(systemName: "star")]),
            N.contextMenu(content: [N.text("Tap")], items: [N.button("Copy", actionID: "copy")])
        ])
        XCTAssertNotNil(render(tree))

        let d = tree.describe()
        XCTAssertTrue(d.contains("StyledText(\"**bold**\",verbatim:false,markdown:true,localized:false)"), d)
        XCTAssertTrue(d.contains("DateText(epoch:1700000000.0,style:timer)"), d)
        XCTAssertTrue(d.contains("Image(systemName:\"wifi\",variableValue:0.5)"), d)
        XCTAssertTrue(d.contains("Image(\"Logo\")"), d)
        XCTAssertTrue(d.contains("AsyncImage(url:\"https://example.com/a.png\",scale:2.0)"), d)
        XCTAssertTrue(d.contains("ProgressView(value:0.4,total:1.0)"), d)
        XCTAssertTrue(d.contains("Gauge(value:5.0,in:0.0...10.0)"), d)
        XCTAssertTrue(d.contains("Link(destination:\"https://example.com\")"), d)
        XCTAssertTrue(d.contains("ShareLink(items:1)"), d)
        XCTAssertTrue(d.contains("SecureField(placeholder:\"Password\""), d)
        XCTAssertTrue(d.contains("TextEditor(text:\"draft\""), d)
        XCTAssertTrue(d.contains("LabeledContent(label:1,content:1)"), d)
        XCTAssertTrue(d.contains("Menu(label:1,items:1)"), d)
        XCTAssertTrue(d.contains("Label(title:1,icon:1)"), d)
        XCTAssertTrue(d.contains("ContextMenu(content:1,items:1)"), d)
    }

    /// The NEW containers + shapes render to a real `AnyView` without trapping.
    @MainActor
    func testRendersNewContainersAndShapes() {
        let tree = N.scrollView(axis: .vertical, [
            N.lazyVStack(alignment: .leading, spacing: 8, [N.text("a")]),
            N.lazyHStack(spacing: 4, [N.text("b")]),
            N.lazyVGrid(columns: [
                IRGridItem(size: .flexible(min: 10, max: .infinity)),
                IRGridItem(size: .fixed(80)),
                IRGridItem(size: .adaptive(min: 40, max: .points(120)))
            ], spacing: 12, [N.text("c")]),
            N.lazyHGrid(rows: [IRGridItem(size: .fixed(50))], [N.text("e")]),
            N.grid(alignment: .topLeading, horizontalSpacing: 8, verticalSpacing: 8, [
                N.gridRow([N.text("r1c1"), N.text("r1c2")])
            ]),
            N.groupBox(label: [N.text("Box")], [N.text("boxed")]),
            N.disclosureGroup(label: [N.text("Section")], [N.text("hidden")]),
            N.viewThatFits(axes: .horizontal, [N.text("wide"), N.text("narrow")]),
            N.controlGroup([N.button("X", actionID: "x")]),
            N.tabView(tabs: [
                IRTab(tag: "home", tabItem: [N.label(title: "Home", systemImage: "house")],
                      content: [N.text("Home screen")])
            ], style: .page),
            N.path([.move(x: 0, y: 0), .line(x: 10, y: 10), .closeSubpath]),
            N.shape(.unevenRoundedRectangle(topLeading: 4, topTrailing: 8,
                                            bottomLeading: 0, bottomTrailing: 12, style: .continuous)),
            N.shape(.containerRelative)
        ])
        XCTAssertNotNil(render(tree))

        let d = tree.describe()
        XCTAssertTrue(d.contains("LazyVStack(align:leading,spacing:8.0)"), d)
        XCTAssertTrue(d.contains("LazyHStack(align:center,spacing:4.0)"), d)
        XCTAssertTrue(d.contains("LazyVGrid(cols:3,spacing:12.0)"), d)
        XCTAssertTrue(d.contains("LazyHGrid(rows:1,spacing:nil)"), d)
        XCTAssertTrue(d.contains("Grid(align:topLeading,h:8.0,v:8.0)"), d)
        XCTAssertTrue(d.contains("GridRow(align:center)"), d)
        XCTAssertTrue(d.contains("GroupBox(label:1)"), d)
        XCTAssertTrue(d.contains("DisclosureGroup(label:1)"), d)
        XCTAssertTrue(d.contains("ViewThatFits(axes:horizontal)"), d)
        XCTAssertTrue(d.contains("ControlGroup"), d)
        XCTAssertTrue(d.contains("TabView(tabs:1,style:page)"), d)
        XCTAssertTrue(d.contains("Path(3 cmds)"), d)
        XCTAssertTrue(d.contains("Shape(urrect(tl:4.0,tr:8.0,bl:0.0,br:12.0,continuous))"), d)
        XCTAssertTrue(d.contains("Shape(containerRelative)"), d)
    }
    #endif

    // MARK: - v3 HOST-STATE tier (presentation / selection / navigation / focus)

    /// `IRValue.array` (nav path / multi-select / index sets) round-trips through both
    /// codecs + synthesized Codable, incl. nesting.
    func testIRValueArrayRoundTrip() throws {
        let values: [IRValue] = [
            .array([.int(0), .int(2), .int(5)]),            // an index set
            .array([.string("Detail"), .string("Edit")]),  // a nav path
            .array([.double(1), .double(2.5)]),
            .array([]),                                     // empty
            .array([.array([.int(1)]), .bool(true)])        // nested + mixed
        ]
        for v in values {
            let data = try JSONEncoder().encode(v)
            XCTAssertEqual(try JSONDecoder().decode(IRValue.self, from: data), v, "\(v)")
        }
        // And carried in a tree node (boundTabView selection) through both codecs.
        let tree = N.tabView(selection: 1, tabs: [
            IRTab(tag: "0", tabItem: [N.text("A")], content: [N.text("a")]),
            IRTab(tag: "1", tabItem: [N.text("B")], content: [N.text("b")])
        ], event: "tab")
        try assertRoundTrips(tree)
    }

    /// Every new host-state NodeKind survives BOTH codecs intact (the precise-shape
    /// check: a mis-shaped manual emitter would fail to decode to the same tree).
    func testHostStateNodesWireRoundTrip() throws {
        let tree = N.navigationStack(path: ["Detail", "Edit"], root: [
            N.picker(label: [N.text("Flavor")], selection: 1, options: [
                IRPickerOption(tag: .int(0), label: [N.text("Vanilla")]),
                IRPickerOption(tag: .int(1), label: [N.text("Chocolate")])
            ], event: "flavor"),
            N.picker(label: [N.text("Sort")], selection: "name", options: [
                IRPickerOption(tag: .string("name"), label: [N.text("Name")]),
                IRPickerOption(tag: .string("date"), label: [N.text("Date")])
            ], event: "sort"),
            N.datePicker(label: [N.text("When")], epoch: 1_700_000_000, components: "date",
                         minEpoch: 1_600_000_000, maxEpoch: 1_800_000_000, event: "when"),
            N.colorPicker(label: [N.text("Tint")], color: IRColor(r: 0.1, g: 0.2, b: 0.3, a: 0.9),
                          supportsOpacity: true, event: "tint"),
            N.navigationLink(destination: [N.text("Detail")], label: [N.text("Go")]),
            N.disclosureGroup(label: [N.text("More")], isExpanded: true,
                              [N.text("hidden")], event: "exp"),
            N.section(header: [N.text("H")], isExpanded: false, [N.text("row")], event: "sec"),
            N.editButton,
            N.button("Delete", actionID: "del", role: .destructive),
            N.button("Cancel", actionID: "cnl", role: .cancel)
        ], destinations: [
            IRNavDestination(typeTag: "Detail", body: [N.text("Detail body")]),
            IRNavDestination(typeTag: "Edit", body: [N.text("Edit body")])
        ], event: "path")
        try assertRoundTrips(tree)
    }

    /// Every new host-state MODIFIER survives BOTH codecs intact.
    func testHostStateModifiersWireRoundTrip() throws {
        let tree = N.text("Body")
            .sheet(presentedKey: "showA", isPresented: false, event: "a", [N.text("Sheet")])
            .sheet(itemKey: "item", itemPresent: true, event: "i", [N.text("Item sheet")])
            .fullScreenCover(presentedKey: "showB", isPresented: true, event: "b", [N.text("Cover")])
            .popover(presentedKey: "showC", isPresented: false, event: "c", [N.text("Pop")])
            .alert("Delete?", presentedKey: "showD", isPresented: false, event: "d",
                   actions: [N.button("OK", actionID: "ok", role: .destructive)],
                   message: [N.text("Sure?")])
            .confirmationDialog("Choose", titleVisibility: "visible", presentedKey: "showE",
                                isPresented: false, event: "e",
                                actions: [N.button("One", actionID: "one")])
            .navigationDestination(presentedKey: "showF", isPresented: false, event: "f", [N.text("Dest")])
            .toolbar(items: [
                IRToolbarItem(placement: "navigationBarTrailing", content: [N.button("Add", actionID: "add")]),
                IRToolbarItem(placement: "bottomBar", content: [N.text("Status")])
            ])
            .navigationBarTitleDisplayMode("inline")
            .navigationBarBackButtonHidden(true)
            .searchable(searchKey: "q", query: "term", prompt: "Search", event: "s")
            .focused(focusKey: "field", equals: "email", isFocused: true, event: "foc")
            .onDelete(event: "del")
            .onMove(event: "mov")
        try assertRoundTrips(tree)
    }

    /// The C-tier `geometryReader` + `canvas` nodes (and every `IRDrawOp` shape)
    /// survive BOTH codecs intact — the wire-format contract the SDK renderer reads.
    func testGeometryReaderAndCanvasWireRoundTrip() throws {
        let tree = N.vstack([
            N.geometryReader(id: "geo_ab12", [
                N.text("child").frame(width: 100, height: 50),
                N.color(.named("blue"))
            ]),
            N.canvas([
                .fillPath(commands: [.addRect(x: 0, y: 0, width: 10, height: 10)],
                          style: .color(.rgba(IRColor(r: 0.1, g: 0.2, b: 0.3, a: 1)))),
                .strokePath(commands: [.move(x: 0, y: 0), .line(x: 5, y: 5), .closeSubpath],
                            style: .color(.named("red")), lineWidth: 2.5),
                .drawText(text: [N.text("T").bold()], x: 3, y: 4, anchor: "topLeading")
            ])
        ])
        try assertRoundTrips(tree)
        // Spot-check the describe dump reflects both nodes.
        let d = tree.describe()
        XCTAssertTrue(d.contains("GeometryReader(#geo_ab12,children:2)"), d)
        XCTAssertTrue(d.contains("Canvas(ops:3)"), d)
    }

    #if canImport(SwiftUI)
    /// The new host-state nodes + modifiers all render to real SwiftUI without trapping.
    @MainActor
    func testRenderHostStateProducesSwiftUI() {
        let tree = N.navigationStack(path: [], root: [
            N.picker(label: [N.text("P")], selection: 0, options: [
                IRPickerOption(tag: .int(0), label: [N.text("Zero")])
            ], event: "p"),
            N.picker(label: [N.text("S")], selection: "x", options: [
                IRPickerOption(tag: .string("x"), label: [N.text("X")])
            ], event: "s2"),
            N.datePicker(label: [N.text("D")], epoch: 0, components: "dateAndTime", minEpoch: nil, maxEpoch: nil, event: "d"),
            N.colorPicker(label: [N.text("C")], color: .black, supportsOpacity: false, event: "c"),
            N.navigationLink(destination: [N.text("Detail")], label: [N.text("Go")]),
            N.disclosureGroup(label: [N.text("M")], isExpanded: true, [N.text("x")], event: "e"),
            N.section(header: [N.text("H")], isExpanded: false, [N.text("r")], event: "sec"),
            N.editButton
        ], destinations: [IRNavDestination(typeTag: "Detail", body: [N.text("Body")])], event: "path")
            .sheet(presentedKey: "k", isPresented: true, event: "ev", [N.text("Sheet")])
            .alert("A?", presentedKey: "ak", isPresented: false, event: "ae",
                   actions: [N.button("OK", actionID: "ok", role: .destructive)])
            .toolbar(items: [IRToolbarItem(placement: "primaryAction", content: [N.button("Add", actionID: "add")])])
            .searchable(searchKey: "q", query: "", prompt: nil, event: "se")
            .focused(focusKey: "f", equals: "one", isFocused: false, event: "fe")
        XCTAssertNotNil(render(tree))
    }

    /// A `Button(role:)` renders (the role reaches the real Button initializer).
    @MainActor
    func testButtonRoleRenders() {
        XCTAssertNotNil(render(N.button("Delete", actionID: "d", role: .destructive)))
        XCTAssertNotNil(render(N.button("Cancel", actionID: "c", role: .cancel)))
        XCTAssertNotNil(render(N.button("Plain", actionID: "p")))
    }

    // MARK: - C — GeometryReader (host-state) + Canvas (draw-op replay)

    /// A `geometryReader` node renders a REAL `GeometryReader` wrapper without
    /// trapping — both with NO rebuild closure (static children render) and with a
    /// rebuild closure (the proxy size/frame are passed and fresh children render).
    @MainActor
    func testGeometryReaderRendersRealGeometryReader() {
        // The lowered child reads the reserved __geo_* inputs as bound guest scalars;
        // here the IR child is a plain subtree (the reserved values arrive at the guest
        // layer, not the renderer). The renderer just builds the GeometryReader host.
        let reader = N.geometryReader(id: "geo_1", [
            N.text("inside").frame(width: 100, height: 50)
        ])
        // No rebuild closure → static children render (a bare render(_:)).
        XCTAssertNotNil(render(reader))
        XCTAssertTrue(reader.describe().contains("GeometryReader(#geo_1,children:1)"), reader.describe())

        // With a rebuild closure: the renderer's GeometryReader host invokes it on each
        // layout with the live proxy size/frame, swapping in fresh children. We verify
        // the closure is wired + invocable (the SwiftUI layout pass that calls it is
        // covered by the live-module path; here we drive the resolve directly).
        var seen: [(String, Double, Double, Double, Double)] = []
        let rebuild = GeometryRebuild { id, w, h, x, y in
            seen.append((id, w, h, x, y))
            return [N.text("w=\(Int(w))")]
        }
        let ctx = RenderContext(geometryRebuild: rebuild)
        XCTAssertNotNil(render(reader, context: ctx))
        // Drive the resolve the way the host wrapper does on a layout pass.
        let fresh = rebuild("geo_1", 320, 200, 0, 0)
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen[0].1, 320)
        XCTAssertEqual(fresh?.first?.describe(), "Text(\"w=320\")")
    }

    /// A `canvas` of the SUPPORTED draw ops (fillPath / strokePath / drawText with
    /// scalar geometry) renders a REAL `Canvas` without trapping; describe reflects it.
    @MainActor
    func testCanvasRendersSupportedDrawOps() {
        let canvas = N.canvas([
            // fill an ellipse-ish path with a color
            .fillPath(commands: [
                .move(x: 0, y: 0), .addRect(x: 0, y: 0, width: 100, height: 80)
            ], style: .color(.named("blue"))),
            // stroke a diagonal line with a gradient
            .strokePath(commands: [.move(x: 0, y: 0), .line(x: 100, y: 80)],
                        style: .linearGradient(
                            IRGradient(stops: [IRGradientStop(color: .named("red"), location: 0),
                                               IRGradientStop(color: .named("orange"), location: 1)]),
                            startPoint: .leading, endPoint: .trailing),
                        lineWidth: 3),
            // draw a styled Text leaf at a point
            .drawText(text: [N.text("hi").font(.init(style: .caption)).foregroundColor(.named("white"))],
                      x: 20, y: 40, anchor: "center")
        ])
        XCTAssertNotNil(render(canvas))
        // describe()'s kind label is "Canvas(ops:3)"; the drawText Text leaf recurses
        // as a child, so assert the label is present (not the whole multi-line dump).
        XCTAssertTrue(canvas.describe().contains("Canvas(ops:3)"), canvas.describe())
    }
    #endif

    /// The host-owned presentation binding: GET returns the guest flag, SET (a system
    /// swipe-dismiss or a button) dispatches the event. Same proven bridge as Toggle.
    @MainActor
    func testPresentationBindingDispatches() throws {
        var captured: [(String, IRValue)] = []
        let dispatcher = Dispatcher { e, v in captured.append((e.id, v)) }
        #if canImport(SwiftUI)
        let r = Renderer(context: RenderContext(dispatcher: dispatcher))
        // GET reflects the guest flag value.
        let binding = r.presentationBinding(true, EventID("dismiss"))
        XCTAssertTrue(binding.wrappedValue, "GET returns the guest-emitted flag")
        // SET (swipe-to-dismiss) dispatches the new value into the guest.
        binding.wrappedValue = false
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured[0].0, "dismiss")
        XCTAssertEqual(captured[0].1, .bool(false))
        #else
        _ = dispatcher
        #endif
    }

    /// The Picker / TabView selection projection helpers extract Int/String tags, and
    /// `onDelete`/`onMove` dispatch `.array([.int])` payloads.
    @MainActor
    func testSelectionAndListEditDispatch() throws {
        #if canImport(SwiftUI)
        XCTAssertEqual(Renderer.intValue(.int(3)), 3)
        XCTAssertEqual(Renderer.intValue(.double(4)), 4)   // coerces
        XCTAssertNil(Renderer.intValue(.string("x")))
        XCTAssertEqual(Renderer.stringValue(.string("sort")), "sort")
        XCTAssertNil(Renderer.stringValue(.int(1)))
        #endif

        // onDelete/onMove ship index sets as `.array([.int])`; the guest mutates its
        // array. Render builds the editable ForEach; here we assert the payload shape
        // by firing the dispatcher the way SwiftUI's swipe/reorder would.
        var captured: [(String, IRValue)] = []
        let dispatcher = Dispatcher { e, v in captured.append((e.id, v)) }
        #if canImport(SwiftUI)
        let editable = N.forEach([N.text("a"), N.text("b"), N.text("c")])
            .onDelete(event: "del").onMove(event: "mov")
        _ = render(editable, context: RenderContext(dispatcher: dispatcher))
        #endif
        // Simulate a delete of rows {0,2} and a move of {0}→2.
        dispatcher.send(EventID("del"), .array([.int(0), .int(2)]))
        dispatcher.send(EventID("mov"), .array([.int(0), .int(2)]))
        XCTAssertEqual(captured.count, 2)
        XCTAssertEqual(captured[0].1, .array([.int(0), .int(2)]))
        XCTAssertEqual(captured[1].1, .array([.int(0), .int(2)]))
    }

    // MARK: - Design-system TOKENS (v4: ColorRef.hostToken / Modifier.fontToken)

    /// The new token cases round-trip through the JSON wire (the boundary the guest
    /// emits and the host decodes), including a token nested in an `IRShapeStyle`.
    func testHostTokenWireRoundTrip() throws {
        let tree = N.vstack([
            N.text("a").foregroundColor(.hostToken("ct_1")).fontToken("ft_1"),
            N.shape(.capsule).fill(.color(.hostToken("ct_2"))),
            N.text("b").tint(.hostToken("ct_3"))
        ])
        let emission = BodyEmission(root: tree, computeCoverage: true,
                                    schemaVersion: PatchViewIRSchema.version)
        let bytes = try ViewNodeWire.encode(emission)
        XCTAssertEqual(try ViewNodeWire.decode(bytes).root, tree,
                       "host-token color + fontToken survive the wire")
        // The Foundation-free embedded emitter produces host-decodable bytes too.
        XCTAssertEqual(try ViewNodeWire.decode(EmbeddedJSON.encode(emission)).root, tree)
    }

    #if canImport(SwiftUI)
    /// The renderer applies a HOST-SUPPLIED token color: `color(.hostToken(id))`
    /// returns the supplied color, and falls back to `.primary` when none is supplied.
    @MainActor
    func testRendererAppliesHostTokenColor() {
        let table = HostTokenTable()
        table.set("ct_x", .color(.red))
        let r = Renderer(context: RenderContext(tokens: table))
        XCTAssertEqual(r.color(.hostToken("ct_x")), Color.red,
                       "a supplied token color is applied")
        XCTAssertEqual(r.color(.hostToken("ct_missing")), Color.primary,
                       "an unsupplied token color falls back to .primary (never wrong brand)")
    }

    /// The renderer applies a HOST-SUPPLIED token font via the `.fontToken` modifier
    /// (renders without trapping; the supplied `Font` is opaque so we assert it routes).
    @MainActor
    func testRendererAppliesHostTokenFont() {
        let table = HostTokenTable()
        table.set("ft_x", .font(.system(size: 28, weight: .heavy)))
        let r = Renderer(context: RenderContext(tokens: table))
        XCTAssertNotNil(table.font(for: "ft_x"))
        XCTAssertNil(table.font(for: "ft_missing"))
        // The full apply path renders without trapping (supplied + missing both safe).
        _ = render(N.text("x").fontToken("ft_x"), context: RenderContext(tokens: table))
        _ = render(N.text("x").fontToken("ft_missing"), context: RenderContext(tokens: table))
    }

    /// A token nested in a `.fill` style resolves to the supplied color (the
    /// `IRShapeStyle.color(.hostToken)` path through `renderShapeStyle`).
    @MainActor
    func testHostTokenInShapeStyleResolves() {
        let table = HostTokenTable()
        table.set("ct_fill", .color(.green))
        let r = Renderer(context: RenderContext(tokens: table))
        // Resolving must not trap; the color() path is exercised by renderShapeStyle.
        _ = r.renderShapeStyle(.color(.hostToken("ct_fill")))
        XCTAssertEqual(r.color(.hostToken("ct_fill")), Color.green)
    }
    #endif
}
