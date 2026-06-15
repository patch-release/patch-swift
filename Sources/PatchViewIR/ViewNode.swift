// ViewNode — the serializable IR for a (declarative) SwiftUI view body.
// ====================================================================
// This file is the SINGLE shared contract between the WASM *guest* (which
// builds + serializes a `ViewNode` tree inside the sandbox) and the native
// *host* renderer (which reconstitutes REAL SwiftUI from the tree). It is pure
// `Codable` + `Foundation`-free value types so it compiles unchanged into a
// `wasm32-unknown-wasip1` (or embedded) module AND into the host SDK.
//
// Design notes
// ------------
// * A `ViewNode` is a `kind` (primitive/container) PLUS an ordered list of
//   `modifiers`. Modifiers are kept as an explicit, ordered list — NOT folded
//   into the node — because SwiftUI modifier *order* is semantically meaningful
//   (`.padding().background()` ≠ `.background().padding()`). The renderer
//   replays them in order.
// * Anything we cannot lower becomes a `.opaque` node (a native fallback slot
//   the host fills from a side table). This is what makes the lowering total:
//   a body never fails to lower; the un-lowerable bits degrade to native.
// * `Codable` with a compact, stable JSON shape (the wire format across the
//   WASM boundary is JSON, matching the engine's proven `callJSON` ABI).

// MARK: - Color

/// An sRGB color carried as components so it survives the boundary without
/// depending on SwiftUI's `Color` (which the guest cannot import).
public struct IRColor: Equatable, Sendable {
    public var r: Double, g: Double, b: Double, a: Double
    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    // The SwiftUI system palette, by name. The guest can reference these by
    // name (`.named`) and the host maps named colors to the *real* system
    // `Color` (so e.g. `.primary` stays adaptive to light/dark). Literal RGBA
    // is used for `Color(red:green:blue:)` and `.opacity`-derived colors.
    public static let black = IRColor(r: 0, g: 0, b: 0)
    public static let white = IRColor(r: 1, g: 1, b: 1)
    public static let clear = IRColor(r: 0, g: 0, b: 0, a: 0)
}

/// A color reference: either a named system color (kept adaptive on the host)
/// or explicit sRGB components.
public enum ColorRef: Equatable, Sendable {
    case named(String)          // "blue", "primary", "secondary", "red", …
    case rgba(IRColor)
    /// A DESIGN-SYSTEM color TOKEN supplied natively by the build-time thunk, keyed
    /// by a content-stable id. The guest's lowered tree carries only the id; the host
    /// app's `__patchTokens()` evaluates the real token expression (`Theme.Colors.ink`,
    /// `Brand.accent`, any `<Type>.<member>[(args)]` of static type `Color`) → a
    /// resolved `Color` it supplies under that id. This lets a token-using modifier
    /// (`.foregroundStyle(Theme.Colors.ink)`, `.fill(Theme.Colors.accent)`) LOWER —
    /// the modifier rides WASM (patchable), its VALUE is host-supplied (the same slot
    /// mechanism as a mixed-view leaf, but for a color value). An OTA patch can
    /// re-select among the tokens the build enumerated; it cannot invent a new native
    /// token (that's the App Store wall). The renderer falls back to `.primary` if the
    /// host supplies no value for the id (and `PatchedBodyHost` demotes the whole view
    /// when a token id is uncovered — never renders a wrong color).
    case hostToken(String)
}

// MARK: - Font

public struct IRFont: Equatable, Sendable {
    public enum Weight: String, Equatable, Sendable {
        case ultraLight, thin, light, regular, medium, semibold, bold, heavy, black
    }
    public enum Design: String, Equatable, Sendable {
        case `default`, serif, rounded, monospaced
    }
    /// A named text style (`.title`, `.body`, …). When set, it takes precedence
    /// over `size`; the host maps it to the real adaptive `Font.TextStyle`.
    public enum TextStyle: String, Equatable, Sendable {
        case largeTitle, title, title2, title3, headline, subheadline
        case body, callout, footnote, caption, caption2
    }
    public var style: TextStyle?
    public var size: Double?
    public var weight: Weight?
    public var design: Design?

    public init(style: TextStyle? = nil, size: Double? = nil,
                weight: Weight? = nil, design: Design? = nil) {
        self.style = style; self.size = size; self.weight = weight; self.design = design
    }
}

// MARK: - Geometry

public struct IREdgeInsets: Equatable, Sendable {
    public var top: Double, leading: Double, bottom: Double, trailing: Double
    public init(top: Double = 0, leading: Double = 0, bottom: Double = 0, trailing: Double = 0) {
        self.top = top; self.leading = leading; self.bottom = bottom; self.trailing = trailing
    }
    public static func all(_ v: Double) -> IREdgeInsets {
        IREdgeInsets(top: v, leading: v, bottom: v, trailing: v)
    }
}

public enum IRAlignment: String, Equatable, Sendable {
    case leading, center, trailing
    case top, bottom
    case topLeading, topTrailing, bottomLeading, bottomTrailing
}

public enum IRHorizontalAlignment: String, Equatable, Sendable {
    case leading, center, trailing
}
public enum IRVerticalAlignment: String, Equatable, Sendable {
    case top, center, bottom, firstTextBaseline, lastTextBaseline
}

public enum IRTextAlignment: String, Equatable, Sendable {
    case leading, center, trailing
}

/// The scroll axis of a `ScrollView`. SwiftUI's default is `.vertical`.
public enum IRScrollAxis: String, Equatable, Sendable {
    case vertical, horizontal
}

/// A single dimension of a flexible `.frame(...)`. JSON has NO representation for
/// `Double.infinity` (encoding `Double.infinity` makes JSONEncoder — and the
/// hand-rolled guest encoder — emit a non-finite token the host can't decode), so
/// a flexible bound is carried as a tagged enum: a finite `.points(x)` or the
/// sentinel `.infinity` (SwiftUI's `.infinity`). The host maps `.infinity` back to
/// `CGFloat.infinity`; the guest JSON encoder mirrors Swift's synthesized Codable
/// shape (`.points(x)` → `{"points":{"_0":x}}`, `.infinity` → `{"infinity":{}}`).
public enum IRLength: Equatable, Sendable {
    case points(Double)
    case infinity
}

// MARK: - Events (the INTERACTIVE additions — Breakthrough #5)

/// An event the host fires back into the guest's `dispatch` when the user
/// interacts with a control. The `id` selects which UPDATE branch runs inside
/// WASM; `payload` carries the new value (a typed scalar) for value-bearing
/// controls (Toggle/Slider/Stepper/TextField). For a bare `.onTapGesture` the
/// payload is `.none`.
///
/// This is the heart of the interactive loop: a control's binding/gesture maps
/// to an `EventID`, the host marshals `{id, payload}` to the guest, and the
/// guest's pure UPDATE function (which runs in WASM) mutates state from it.
public struct EventID: Equatable, Sendable {
    public var id: String
    public init(_ id: String) { self.id = id }
}

/// A typed value crossing the boundary in an event payload (or as a control's
/// current bound value when emitting the tree). Kept Foundation-free.
public enum IRValue: Equatable, Sendable {
    case none
    case bool(Bool)
    case double(Double)
    case int(Int)
    case string(String)
    /// A 2-D point (`x`, `y`). Used by continuous gestures (a `DragGesture`'s
    /// `value.translation` ships as `.point(dx, dy)`; the guest does the drag
    /// arithmetic in WASM). Encodes as `{"point":{"_0":x,"_1":y}}`.
    case point(Double, Double)
    /// An ordered list of values. Carries a navigation path (`[PathToken]`),
    /// a multi-selection set, or an index set (`onDelete`/`onMove` offsets) across
    /// the boundary — the host-state constructs whose payload is a sequence rather
    /// than a scalar. Encodes as `{"array":{"_0":[<IRValue>,…]}}` (Swift's
    /// synthesized single-unlabeled-payload shape); each element recurses.
    indirect case array([IRValue])
}

// MARK: - Unified style vocabulary (IRShapeStyle and friends)

/// A 2-D unit point (0…1 in each axis) for gradient geometry, transform anchors,
/// etc. Carries named-case fast-paths (`.center`, `.top`, …) the host maps back
/// to SwiftUI's `UnitPoint` statics; an arbitrary point uses `.xy`.
public enum IRUnitPoint: Equatable, Sendable {
    case center, top, bottom, leading, trailing
    case topLeading, topTrailing, bottomLeading, bottomTrailing
    case xy(x: Double, y: Double)
}

/// A single gradient stop: a color at a normalized location (0…1).
public struct IRGradientStop: Equatable, Sendable {
    public var color: ColorRef
    public var location: Double
    public init(color: ColorRef, location: Double) {
        self.color = color; self.location = location
    }
}

/// The stops of a gradient. The geometry (linear/radial/angular) lives on the
/// enclosing `IRShapeStyle` case so the same stop list reuses across forms.
public struct IRGradient: Equatable, Sendable {
    public var stops: [IRGradientStop]
    public init(stops: [IRGradientStop]) { self.stops = stops }
}

/// SwiftUI's built-in blur `Material` levels.
public enum IRMaterial: String, Equatable, Sendable {
    case ultraThin, thin, regular, thick, bar
}

/// A `StrokeStyle`: the geometry of a stroked path/border.
public struct IRStrokeStyle: Equatable, Sendable {
    public var lineWidth: Double
    public var cap: String          // "butt" | "round" | "square"
    public var join: String         // "miter" | "round" | "bevel"
    public var miterLimit: Double
    public var dash: [Double]
    public var dashPhase: Double
    public init(lineWidth: Double = 1, cap: String = "butt", join: String = "miter",
                miterLimit: Double = 10, dash: [Double] = [], dashPhase: Double = 0) {
        self.lineWidth = lineWidth; self.cap = cap; self.join = join
        self.miterLimit = miterLimit; self.dash = dash; self.dashPhase = dashPhase
    }
}

/// A drop-shadow style carried by `IRShapeStyle.shadow` (the ShapeStyle form).
public struct IRShadowStyle: Equatable, Sendable {
    public var color: ColorRef?
    public var radius: Double
    public var x: Double
    public var y: Double
    public init(color: ColorRef? = nil, radius: Double, x: Double = 0, y: Double = 0) {
        self.color = color; self.radius = radius; self.x = x; self.y = y
    }
}

/// The UNIFIED styling vocabulary shared by `foregroundStyle`/`background`/
/// `tint`/`fill`/`stroke`/`border`/`overlay`. The engine resolves a concrete
/// `ShapeStyle` at lowering time into one of these cases; the SDK's
/// `renderShapeStyle` rebuilds a real `AnyShapeStyle`.
public indirect enum IRShapeStyle: Equatable, Sendable {
    case color(ColorRef)
    case linearGradient(IRGradient, startPoint: IRUnitPoint, endPoint: IRUnitPoint)
    case radialGradient(IRGradient, center: IRUnitPoint, startRadius: Double, endRadius: Double)
    case angularGradient(IRGradient, center: IRUnitPoint, startAngle: Double, endAngle: Double)
    case material(IRMaterial)
    /// A hierarchical level (0 = `.primary`, 1 = `.secondary`, … 4 = `.quinary`).
    case hierarchical(Int)
    /// A semantic style by name: "tint" | "foreground" | "separator" |
    /// "placeholder" | "link" (mapped to the real `ShapeStyle` static).
    case semantic(String)
    case shadow(IRShadowStyle)
}

/// `.aspectRatio`/`Image.resizable` content mode.
public enum IRContentMode: String, Equatable, Sendable {
    case fit, fill
}

/// A blend mode (the full SwiftUI `BlendMode` enum, mirrored by raw name).
public enum IRBlendMode: String, Equatable, Sendable {
    case normal, multiply, screen, overlay, darken, lighten
    case colorDodge, colorBurn, softLight, hardLight, difference, exclusion
    case hue, saturation, color, luminosity
    case sourceAtop, destinationOver, destinationOut, plusDarker, plusLighter
}

/// Animation parameters as pure data (`.animation(_:value:)`). The host rebuilds
/// a real `Animation` from the `curve` + the relevant scalar params.
public struct IRAnimation: Equatable, Sendable {
    /// The curve family: "default" | "linear" | "easeIn" | "easeOut" |
    /// "easeInOut" | "spring" | "interpolatingSpring" | "bouncy" | "smooth" | "snappy".
    public var curve: String
    public var duration: Double?
    public var response: Double?
    public var dampingFraction: Double?
    public var delay: Double?
    public var speed: Double?
    public var repeatCount: Int?
    public var autoreverses: Bool?
    public init(curve: String, duration: Double? = nil, response: Double? = nil,
                dampingFraction: Double? = nil, delay: Double? = nil, speed: Double? = nil,
                repeatCount: Int? = nil, autoreverses: Bool? = nil) {
        self.curve = curve; self.duration = duration; self.response = response
        self.dampingFraction = dampingFraction; self.delay = delay; self.speed = speed
        self.repeatCount = repeatCount; self.autoreverses = autoreverses
    }
}

/// A view transition (`.transition(_:)`). The named built-ins map to the real
/// `AnyTransition` statics; `.combined`/`.asymmetric` compose recursively.
public indirect enum IRTransition: Equatable, Sendable {
    case identity
    case opacity
    case scale(scale: Double, anchor: IRUnitPoint)
    case slide
    case move(edge: String)          // "top"|"bottom"|"leading"|"trailing"
    case push(edge: String)
    case offset(x: Double, y: Double)
    case blurReplace
    case combined([IRTransition])
    case asymmetric(insertion: IRTransition, removal: IRTransition)
}

// MARK: - Leaf-view supporting value types (A.1)

/// The self-ticking style of a `Text(date, style:)`. The guest emits a `Double`
/// epoch (seconds since 1970) + the style; the host reconstructs the `Date` and a
/// real self-ticking `Text(_:style:)`.
public enum IRDateTextStyle: String, Equatable, Sendable {
    case date, time, relative, offset, timer
}

/// `Gauge`'s built-in form (iOS 16+). The host degrades to `ProgressView(value:)`
/// on platforms without `Gauge`.
public struct IRGaugeData: Equatable, Sendable {
    public var value: Double
    public var min: Double
    public var max: Double
    public init(value: Double, min: Double = 0, max: Double = 1) {
        self.value = value; self.min = min; self.max = max
    }
}

// MARK: - Container supporting value types (A.3)

/// A `LazyVGrid`/`LazyHGrid` track sizing (`GridItem.Size`). Carried as a tagged
/// enum so it survives the boundary without SwiftUI's `GridItem`.
public enum IRGridItemSize: Equatable, Sendable {
    case fixed(Double)
    case flexible(min: Double, max: IRLength)     // max may be `.infinity`
    case adaptive(min: Double, max: IRLength)
}

/// One column/row track of a `LazyVGrid`/`LazyHGrid`.
public struct IRGridItem: Equatable, Sendable {
    public var size: IRGridItemSize
    public var spacing: Double?
    public var alignment: IRAlignment?
    public init(size: IRGridItemSize, spacing: Double? = nil, alignment: IRAlignment? = nil) {
        self.size = size; self.spacing = spacing; self.alignment = alignment
    }
}

/// `ViewThatFits(in:)` axes. SwiftUI's default is "both" (no axis arg).
public enum IRAxisSet: String, Equatable, Sendable {
    case horizontal, vertical, both
}

/// A `TabView` tab: a string tag, the `.tabItem` label subtree, and the tab's
/// content subtree. UNBOUND (no selection binding yet) — SwiftUI owns the
/// selected tab; a bound `TabView(selection:)` is a later host-state task.
public struct IRTab: Equatable, Sendable {
    public var tag: String
    public var tabItem: [ViewNode]
    public var content: [ViewNode]
    public init(tag: String, tabItem: [ViewNode], content: [ViewNode]) {
        self.tag = tag; self.tabItem = tabItem; self.content = content
    }
}

/// The (data-only) `.tabViewStyle(...)` flag carried on a `tabView` node.
public enum IRTabViewStyle: String, Equatable, Sendable {
    case automatic, page
}

// MARK: - Host-state supporting value types (B — presentation / selection / nav)

/// A `Button(role:)` semantic role. `.destructive` renders red + (in an alert /
/// confirmationDialog) sorts last; `.cancel` is bold + dismisses. A nil role is
/// the default button. Used by alert/confirmationDialog/context-menu action
/// buttons (auto-wired via the existing actionID path) and standalone buttons.
public enum IRButtonRole: String, Equatable, Sendable {
    case destructive, cancel
}

/// One `Picker` option: the tag value the selection takes when this row is picked
/// (the typed projection that crosses the boundary — Int/String/enum-raw) plus the
/// row's label subtree. A custom Hashable tag that doesn't reduce to one of these
/// makes the whole Picker slot (faithful over wrong).
public struct IRPickerOption: Equatable, Sendable {
    /// The tag value as a typed `IRValue` (`.int`/`.string`). On selection the host
    /// dispatches the Picker's event with THIS value; the guest assigns it.
    public var tag: IRValue
    public var label: [ViewNode]
    public init(tag: IRValue, label: [ViewNode]) {
        self.tag = tag; self.label = label
    }
}

/// The kind of a `Picker`'s selection value — tells the host which `Binding<T>` to
/// build (a `Picker` is generic over its `SelectionValue`, so the renderer needs
/// the concrete projection). `int` and `string` cover Int/enum-raw-Int and
/// String/enum-raw-String tags (the lowerable cases).
public enum IRSelectionKind: String, Equatable, Sendable {
    case int, string
}

/// One `.navigationDestination(for: T.self) { value in body }` entry: a pushed
/// value's `typeTag` (a stable string for the value type, e.g. its type name) →
/// the lowered destination body. When a token of that type is on the path, the
/// host renders this body (the pushed value is a guest input marshalled into it).
public struct IRNavDestination: Equatable, Sendable {
    public var typeTag: String
    public var body: [ViewNode]
    public init(typeTag: String, body: [ViewNode]) {
        self.typeTag = typeTag; self.body = body
    }
}

/// One `toolbar { ToolbarItem(placement:) { content } }` item. `placement` is the
/// `ToolbarItemPlacement` by name ("automatic"|"principal"|"navigationBarLeading"|
/// "navigationBarTrailing"|"topBarLeading"|"topBarTrailing"|"bottomBar"|"primaryAction"|
/// "confirmationAction"|"cancellationAction"|"destructiveAction"|"status"|"keyboard");
/// `content` is a lowered subtree (usually a Button auto-wired via the actionID path).
public struct IRToolbarItem: Equatable, Sendable {
    public var placement: String
    public var content: [ViewNode]
    public init(placement: String, content: [ViewNode]) {
        self.placement = placement; self.content = content
    }
}

// MARK: - Canvas draw ops (C — GeometryReader/Canvas promotion)

/// One serialized `GraphicsContext` draw command, replayed by a host `Canvas`
/// using the in-binary `GraphicsContext`. The guest emits CONCRETE scalar
/// geometry (coords/sizes/line widths the guest computed in WASM — including from
/// the canvas size, injected as reserved `__canvas_width`/`__canvas_height`
/// inputs), so a host `Canvas` replays them faithfully without any native draw
/// code. The COMMON DECLARATIVE forms are modeled — `ctx.fill(Path, with:)`,
/// `ctx.stroke(Path, with:, lineWidth:)`, `ctx.draw(Text, at:)`; an imperative /
/// computed draw (a layer, a clip, a `GraphicsContext` transform, a custom
/// `Shading`) is NOT modeled — the whole `Canvas` demotes to a native slot.
public indirect enum IRDrawOp: Equatable, Sendable {
    /// `ctx.fill(Path(<commands>), with: <style>)` — fill a path with a ShapeStyle.
    case fillPath(commands: [IRPathCommand], style: IRShapeStyle)
    /// `ctx.stroke(Path(<commands>), with: <style>, lineWidth: <w>)` — stroke a path.
    case strokePath(commands: [IRPathCommand], style: IRShapeStyle, lineWidth: Double)
    /// `ctx.draw(Text("…")[.font/.foregroundStyle], at: CGPoint(x:,y:)[, anchor:])` —
    /// draw a (resolved) Text leaf at a point. `text` is a lowered Text subtree (so
    /// its font/color/etc. modifiers replay); `anchor` is a named UnitPoint
    /// ("center"|"topLeading"|… — default "center").
    case drawText(text: [ViewNode], x: Double, y: Double, anchor: String)
}

// MARK: - Path commands (A.2 — NODE side only; fill/stroke are modifiers)

/// A single `Path`/`CGPath` drawing command with concrete scalar coordinates. The
/// guest emits literal coords; the host replays them into a real `Path`. Mirrors
/// the common `Path` builder methods. (Arc/`addArc` reads runtime trig the guest
/// can't always express under Embedded Swift, so it's intentionally omitted — an
/// arc-bearing path stays `.opaque`.)
public enum IRPathCommand: Equatable, Sendable {
    case move(x: Double, y: Double)
    case line(x: Double, y: Double)
    case quad(cpx: Double, cpy: Double, x: Double, y: Double)
    case curve(cp1x: Double, cp1y: Double, cp2x: Double, cp2y: Double, x: Double, y: Double)
    case closeSubpath
    case addRect(x: Double, y: Double, width: Double, height: Double)
    case addRoundedRect(x: Double, y: Double, width: Double, height: Double, cornerRadius: Double)
}

// MARK: - Modifiers

/// An ordered, serializable view modifier. Replayed in order by the host.
public enum Modifier: Equatable, Sendable {
    case font(IRFont)
    case foregroundColor(ColorRef)        // .foregroundColor / .foregroundStyle
    case bold
    case italic
    case padding(IREdgeInsets)
    case frame(width: Double?, height: Double?, alignment: IRAlignment?)
    case background(ColorRef)
    case cornerRadius(Double)
    case opacity(Double)
    case lineLimit(Int?)
    case multilineTextAlignment(IRTextAlignment)
    /// `.onTapGesture { ... }` — LOWERED as an event: the host attaches a tap
    /// recognizer that dispatches `event` into the guest. (Continuous/tracking
    /// gestures like drag still fall back; a discrete tap is just an event.)
    case onTapGesture(EventID)
    /// `.navigationTitle("Title")` — the inline navigation-bar title for the
    /// content of a `NavigationStack`/`NavigationView`. Lowered as a string; the
    /// host replays it with the real `.navigationTitle(_:)` modifier.
    case navigationTitle(String)
    /// A FLEXIBLE `.frame(minWidth:idealWidth:maxWidth:minHeight:idealHeight:maxHeight:alignment:)`
    /// — any subset, where each bound may be `.infinity` (`maxWidth: .infinity`).
    /// Distinct from the fixed `.frame(width:height:)` case because the flexible
    /// frame's `CGFloat?` bounds (incl. `.infinity`) need the JSON-safe `IRLength`.
    case flexFrame(minWidth: IRLength?, idealWidth: IRLength?, maxWidth: IRLength?,
                   minHeight: IRLength?, idealHeight: IRLength?, maxHeight: IRLength?,
                   alignment: IRAlignment?)
    /// `.tint(color)` — the control accent color. Carries a `ColorRef` so it
    /// supports both system-palette names and explicit `Color(red:…)` RGBA.
    case tint(ColorRef)
    /// `.clipShape(shape)` — clips the view to a `ShapeKind` (Circle/Capsule/
    /// RoundedRectangle/Rectangle/Ellipse). The host rebuilds the concrete Shape.
    case clipShape(ShapeKind)
    /// `Shape.trim(from:to:)` — trims a Shape to the `[from, to]` fraction of its
    /// path (the progress-ring idiom: `Circle().trim(from: 0, to: progress)`). The
    /// `from`/`to` are guest-computed Doubles (so a `progress` input drives it). Only
    /// meaningful on a Shape node; on a non-Shape view the renderer ignores it.
    case trim(from: Double, to: Double)
    /// `.disabled(Bool)` from a BOOL LITERAL (`true`/`false`). A non-literal
    /// `.disabled(expr)` stays native (slotted) — only the literal lowers.
    case disabled(Bool)
    /// `.fixedSize()` — the view sizes to its ideal in both dimensions.
    case fixedSize
    /// `.font(<design-system font token>)` — a font from a design-system token
    /// (`Theme.Font.body(13, weight: .semibold)`, any `<expr>` of static type `Font`)
    /// supplied natively by the build-time thunk, keyed by a content-stable id. `Font`
    /// has no introspectable descriptor, so (unlike a color) it can't ride the wire as
    /// data — it rides as an OPAQUE host-supplied `Font` the renderer applies. The
    /// guest tree carries only the id; the host's `__patchTokens()` evaluates the real
    /// expression → a `Font`. Lets `.font(Theme.Font.body(...))` LOWER (the modifier
    /// rides WASM; its value is host-supplied — the slot pattern, for a font value).
    case fontToken(String)

    // MARK: Styling (the unified IRShapeStyle vocabulary)

    /// `.foregroundStyle(_:)` with 1–3 style layers (primary/secondary/tertiary).
    /// The color-only form keeps decoding via the legacy `foregroundColor` case.
    case foregroundStyle([IRShapeStyle])
    /// `.background { content }` (+ optional alignment) — a view-builder backing.
    case backgroundContent(alignment: IRAlignment?, content: [ViewNode])
    /// `.background(style, in: shape?)` — a `ShapeStyle` backing, optionally
    /// clipped to a shape (`nil` = the view's own rectangle).
    case backgroundStyle(IRShapeStyle, in: ShapeKind?)
    /// `.tint(style)` — the `ShapeStyle` form (`.tint(.blue.gradient)`). The
    /// color-only form keeps decoding via the legacy `tint` case.
    case tintStyle(IRShapeStyle)
    /// `.fill(style, eoFill:)` — fill a shape with a `ShapeStyle`.
    case fill(IRShapeStyle, eoFill: Bool)
    /// `.stroke(style, strokeStyle)` — stroke a shape.
    case stroke(IRShapeStyle, IRStrokeStyle)
    /// `.strokeBorder(style, strokeStyle)` — inset stroke for an `InsettableShape`.
    case strokeBorder(IRShapeStyle, IRStrokeStyle)
    /// `.border(style, width:)`.
    case border(IRShapeStyle, width: Double)
    /// `.overlay { content }` (+ optional alignment) — a view-builder overlay.
    case overlayContent(alignment: IRAlignment?, content: [ViewNode])
    /// `.overlay(style, in: shape)` — a `ShapeStyle` overlay clipped to a shape.
    case overlayStyle(IRShapeStyle, in: ShapeKind)
    /// `.shadow(color:radius:x:y:)` — the drop-shadow modifier (distinct from the
    /// `IRShapeStyle.shadow` ShapeStyle form).
    case shadow(color: ColorRef?, radius: Double, x: Double, y: Double)
    /// `.mask(alignment:) { mask }` — the mask content is a recursive subtree.
    case mask(alignment: IRAlignment?, content: [ViewNode])

    // MARK: Layout

    /// `.offset(x:y:)`.
    case offset(x: Double, y: Double)
    /// `.position(x:y:)`.
    case position(x: Double, y: Double)
    /// `.aspectRatio(ratio?, contentMode:)`. `scaledToFit`/`scaledToFill` lower to
    /// this with `ratio: nil` and the corresponding mode.
    case aspectRatio(ratio: Double?, IRContentMode)
    /// `.clipped(antialiased:)`.
    case clipped(antialiased: Bool)
    /// `.fixedSize(horizontal:vertical:)` — the axis form (the no-arg form is
    /// `fixedSize`).
    case fixedSizeAxis(horizontal: Bool, vertical: Bool)
    /// `.layoutPriority(_:)`.
    case layoutPriority(Double)
    /// `.safeAreaInset(edge:alignment:spacing:) { content }`.
    case safeAreaInset(edge: String, alignment: IRAlignment?, spacing: Double?, content: [ViewNode])
    /// `.ignoresSafeArea(_:edges:)` — regions ("all"|"container"|"keyboard") +
    /// edges ("all"|"top"|"bottom"|"leading"|"trailing"|"horizontal"|"vertical").
    case ignoresSafeArea(regions: String, edges: String)
    /// `.zIndex(_:)`.
    case zIndex(Double)
    /// `.containerRelativeFrame(_:alignment:)` — axes ("horizontal"|"vertical"|"all").
    case containerRelativeFrame(axes: String, alignment: IRAlignment?)
    /// `.allowsHitTesting(_:)` from a BOOL LITERAL — whether the view participates
    /// in hit testing (an overlay gradient often disables it). A non-literal
    /// `.allowsHitTesting(expr)` slots (only the literal lowers).
    case allowsHitTesting(Bool)
    /// `.scrollClipDisabled(_:)` — disable a scroll view's content clipping (bool
    /// literal; the no-arg form defaults to `true`).
    case scrollClipDisabled(Bool)
    /// `.scrollContentBackground(_:)` — Visibility ("automatic"|"hidden"|"visible")
    /// of a scrollable container's (List/Form/TextEditor) background.
    case scrollContentBackground(String)
    /// `.listRowSeparator(_:edges:)` — Visibility ("automatic"|"hidden"|"visible")
    /// of a List row's separator. `edges` is the Edge.Set ("all"|"top"|"bottom").
    case listRowSeparator(String, edges: String)
    /// `.listRowBackground(view)` — a List row's background view (a lowered subtree;
    /// a non-lowerable backing becomes an opaque leaf inside it).
    case listRowBackground([ViewNode])
    /// `.listRowInsets(EdgeInsets)` — a List row's content insets.
    case listRowInsets(IREdgeInsets)
    /// `.listSectionSeparator(_:edges:)` — Visibility of a List section's separator.
    case listSectionSeparator(String, edges: String)

    // MARK: Transforms & visual effects

    /// `.rotationEffect(.degrees(d), anchor:)`.
    case rotationEffect(degrees: Double, anchor: IRUnitPoint?)
    /// `.rotation3DEffect(.degrees(d), axis:(x,y,z), anchor:, anchorZ:, perspective:)`.
    case rotation3DEffect(degrees: Double, x: Double, y: Double, z: Double,
                          anchor: IRUnitPoint?, anchorZ: Double, perspective: Double)
    /// `.scaleEffect(x:y:anchor:)`.
    case scaleEffect(x: Double, y: Double, anchor: IRUnitPoint?)
    /// `.blur(radius:opaque:)`.
    case blur(radius: Double, opaque: Bool)
    /// `.brightness(_:)`.
    case brightness(Double)
    /// `.contrast(_:)`.
    case contrast(Double)
    /// `.saturation(_:)`.
    case saturation(Double)
    /// `.grayscale(_:)`.
    case grayscale(Double)
    /// `.hueRotation(.degrees(d))`.
    case hueRotation(degrees: Double)
    /// `.colorInvert()`.
    case colorInvert
    /// `.blendMode(_:)`.
    case blendMode(IRBlendMode)

    // MARK: Text styling

    /// `.fontWeight(_:)`.
    case fontWeight(IRFont.Weight?)
    /// `.fontDesign(_:)`.
    case fontDesign(IRFont.Design?)
    /// `.underline(_:color:)`.
    case underline(active: Bool, color: ColorRef?)
    /// `.strikethrough(_:color:)`.
    case strikethrough(active: Bool, color: ColorRef?)
    /// `.kerning(_:)`.
    case kerning(Double)
    /// `.tracking(_:)`.
    case tracking(Double)
    /// `.baselineOffset(_:)`.
    case baselineOffset(Double)
    /// `.lineSpacing(_:)`.
    case lineSpacing(Double)
    /// `.textCase(_:)` — "uppercase" | "lowercase" | nil (none).
    case textCase(String?)
    /// `.minimumScaleFactor(_:)`.
    case minimumScaleFactor(Double)
    /// `.truncationMode(_:)` — "head" | "middle" | "tail".
    case truncationMode(String)
    /// `.monospaced()`.
    case monospaced
    /// `.monospacedDigit()`.
    case monospacedDigit
    /// `.redacted(reason:)` — "placeholder" | "privacy" | "invalidated".
    case redacted(reason: String)
    /// `.unredacted()`.
    case unredacted
    /// `.symbolRenderingMode(_:)` — "monochrome" | "hierarchical" | "palette" | "multicolor".
    case symbolRenderingMode(String)
    /// `.symbolVariant(_:)` — "none" | "circle" | "square" | "rectangle" | "fill" | "slash".
    case symbolVariant(String)
    /// `.imageScale(_:)` — "small" | "medium" | "large".
    case imageScale(String)
    /// `.dynamicTypeSize(_:)` — a single size name (e.g. "large", "xLarge").
    case dynamicTypeSize(String)

    // MARK: Control config (built-in style enums as pure data)

    case buttonStyle(IRButtonStyle)
    case listStyle(IRListStyle)
    case pickerStyle(String)             // "automatic"|"inline"|"menu"|"segmented"|"wheel"|"palette"|"navigationLink"
    case toggleStyle(String)             // "automatic"|"switch"|"button"|"checkbox"
    case labelStyle(String)              // "automatic"|"iconOnly"|"titleOnly"|"titleAndIcon"
    case gaugeStyle(String)
    case progressViewStyle(String)       // "automatic"|"linear"|"circular"
    case menuStyle(String)               // "automatic"|"button"|"borderlessButton"
    case buttonBorderShape(String)       // "automatic"|"capsule"|"roundedRectangle"|"circle"
    case controlSize(String)             // "mini"|"small"|"regular"|"large"|"extraLarge"
    case tabViewStyle(String)            // "automatic"|"page"|"page.always"|"page.never"
    case indexViewStyle(String)          // "page"|"page.always"|"page.never"
    case keyboardType(String)
    case textContentType(String)
    case autocorrectionDisabled(Bool)
    case textInputAutocapitalization(String)   // "never"|"words"|"sentences"|"characters"
    case submitLabel(String)             // "done"|"go"|"send"|"join"|"route"|"search"|"return"|"next"|"continue"
    case preferredColorScheme(String?)   // "light"|"dark"|nil
    case accentColor(ColorRef?)

    // MARK: Gestures

    /// `.onLongPressGesture(minimumDuration:) { ... }`.
    case onLongPressGesture(minimumDuration: Double, EventID)
    /// `.gesture(DragGesture(minimumDistance:).onChanged{}.onEnded{})`. The host
    /// ships `value.translation` as `IRValue.point` to the onChanged/onEnded events.
    case dragGesture(minDistance: Double, onChanged: EventID?, onEnded: EventID?)
    /// `.gesture(MagnifyGesture()...)` — ships the magnification as `.double`.
    case magnifyGesture(EventID)
    /// `.gesture(RotateGesture()...)` — ships the rotation radians as `.double`.
    case rotateGesture(EventID)

    // MARK: Lifecycle

    /// `.onAppear { ... }`.
    case onAppear(EventID)
    /// `.onDisappear { ... }`.
    case onDisappear(EventID)
    /// `.onChange(of: value) { ... }` — watches a marshalled scalar by key.
    case onChange(valueKey: String, EventID)
    /// `.task(id:) { ... }` — SwiftUI-managed Task running on the async pump.
    case task(EventID, id: String?)
    /// `.onSubmit { ... }`.
    case onSubmit(EventID)
    /// `.onHover { ... }` — ships the hovering Bool as `.bool`.
    case onHover(EventID)
    /// `.sensoryFeedback(_:trigger:)` — a haptic kind fired on a trigger change.
    case sensoryFeedback(kind: String, triggerKey: String)

    // MARK: Animation

    /// `.animation(_:value:)`. A `nil` animation disables animation for the value.
    case animation(IRAnimation?, valueKey: String)
    /// `.transition(_:)`.
    case transition(IRTransition)

    // MARK: Host-state — presentation (B.2)
    //
    // The SDK owns the SwiftUI presentation machinery; the binding's GET reads the
    // guest-emitted flag/item value (carried on the modifier), and its SET (incl. a
    // system-initiated swipe-to-dismiss) dispatches `event` into the guest's
    // `dispatch`, which clears/sets the enclosing presentation flag and re-emits.
    // The content is a lowered subtree shown inside the real `.sheet`/`.alert`/etc.

    /// `.sheet(isPresented: $flag) { content }`. `presentedKey` is the guest state
    /// field name whose Bool the binding reflects; `isPresented` is its CURRENT
    /// value (emit-time snapshot); `event` is dispatched on present/dismiss with the
    /// new `.bool`. `content` is the sheet body (lowered).
    case sheet(presentedKey: String, isPresented: Bool, content: [ViewNode], event: EventID)
    /// `.sheet(item: $item) { item in content }`. `itemPresent` is whether an item
    /// is currently set (emit-time); on a swipe-dismiss the host dispatches `event`
    /// with `.bool(false)` (the guest clears its optional). The item's own value is a
    /// guest input already marshalled into `content` (which lowered against it).
    case sheetItem(itemKey: String, itemPresent: Bool, content: [ViewNode], event: EventID)
    /// `.fullScreenCover(isPresented:) { content }` — same bridge as `.sheet`;
    /// degrades to `.sheet` on macOS (graceful).
    case fullScreenCover(presentedKey: String, isPresented: Bool, content: [ViewNode], event: EventID)
    /// `.popover(isPresented:) { content }` — same Bool bridge as `.sheet`.
    case popover(presentedKey: String, isPresented: Bool, content: [ViewNode], event: EventID)
    /// `.alert(title, isPresented: $flag) { actions } message: { message }`.
    /// `actions`/`message` are lowered subtrees (action Buttons auto-wire via the
    /// existing actionID path, incl. `Button(role:)`). On dismiss the host dispatches
    /// `event` with `.bool(false)`.
    case alert(title: String, presentedKey: String, isPresented: Bool,
               actions: [ViewNode], message: [ViewNode], event: EventID)
    /// `.confirmationDialog(title, isPresented: $flag, titleVisibility:) { actions }
    /// message: { message }`. Same bridge as `.alert`; `titleVisibility` is
    /// "automatic"|"visible"|"hidden".
    case confirmationDialog(title: String, titleVisibility: String, presentedKey: String,
                            isPresented: Bool, actions: [ViewNode], message: [ViewNode], event: EventID)
    /// `.navigationDestination(isPresented: $flag) { destination }` — a Bool-bound
    /// push, like `.sheet(isPresented:)` but driving a navigation push.
    case navigationDestinationBool(presentedKey: String, isPresented: Bool,
                                   destination: [ViewNode], event: EventID)

    // MARK: Host-state — navigation chrome / toolbar (B.2)

    /// `.toolbar { ToolbarItem(placement:) { … } … }` — a list of placed items
    /// (content usually an auto-wired Button). The host replays each as a real
    /// `ToolbarItem(placement:)`.
    case toolbar(items: [IRToolbarItem])
    /// `.navigationBarTitleDisplayMode(_:)` — "automatic"|"inline"|"large".
    case navigationBarTitleDisplayMode(String)
    /// `.navigationBarBackButtonHidden(_:)` (bool literal).
    case navigationBarBackButtonHidden(Bool)
    /// `.presentationDetents([.medium, .large, .fraction(0.5), .height(200)])`. Each
    /// detent is encoded as a string: "medium" | "large" | "fraction:<n>" |
    /// "height:<n>". A `Set`-bound selection form (`selection:`) is NOT modeled
    /// (the detents alone ride; the array form is the dominant idiom).
    case presentationDetents([String])
    /// `.presentationDragIndicator(_:)` — Visibility ("automatic"|"hidden"|"visible").
    case presentationDragIndicator(String)
    /// `.navigationBarTitle(_, displayMode:)` (legacy/deprecated nav title API) — the
    /// title string + a display mode ("automatic"|"inline"|"large").
    case navigationBarTitle(String, displayMode: String)
    /// `.navigationViewStyle(_:)` — "automatic"|"stack"|"columns".
    case navigationViewStyle(String)
    /// `.environment(\.<key>, <value>)` for a small set of reconstructable
    /// environment keys: `layoutDirection` ("leftToRight"|"rightToLeft"),
    /// `colorScheme` ("light"|"dark"), `locale` (a BCP-47 identifier string). The
    /// renderer applies the real per-key `.environment(...)`. An unrecognized key or
    /// non-literal value slots (the modifier stays native).
    case environmentValue(key: String, value: String)

    // MARK: Accessibility (G8)

    /// `.accessibilityLabel(_:)` — a string-literal label.
    case accessibilityLabel(String)
    /// `.accessibilityHint(_:)` — a string-literal hint.
    case accessibilityHint(String)
    /// `.accessibilityValue(_:)` — a string-literal value.
    case accessibilityValue(String)
    /// `.accessibilityHidden(_:)` — a bool literal.
    case accessibilityHidden(Bool)
    /// `.accessibilityAddTraits(_:)` — one or more trait names (`isButton`,
    /// `isHeader`, `isSelected`, `isImage`, etc.) joined with "+".
    case accessibilityAddTraits(String)
    /// `.accessibilityRemoveTraits(_:)` — trait names joined with "+".
    case accessibilityRemoveTraits(String)

    // MARK: Host-state — search / focus (B.2 / B.1)

    /// `.searchable(text: $query[, prompt:])` — a system search bar bound to the
    /// guest's `searchKey` String field (a TextField-style bridge); filtering is
    /// guest body logic. On edit the host dispatches `event` with `.string`.
    case searchable(searchKey: String, query: String, prompt: String?, event: EventID)
    /// `.focused($field, equals: value)` — binds the SDK-owned `@FocusState<String?>`
    /// to the guest's `focusKey`. `equalsToken` is the field's tag string; when the
    /// guest's focus value equals it the field is focused. On focus change the host
    /// dispatches `event` with the new `.string` token (or empty for unfocused).
    case focused(focusKey: String, equalsToken: String, isFocused: Bool, event: EventID)

    // MARK: Host-state — list editing (B.2)

    /// `.onDelete { offsets in … }` on a ForEach row set. On a swipe-delete the host
    /// dispatches `event` with `.array([.int])` of the deleted offsets; the guest
    /// mutates its array. (Attached to the lowered ForEach/list content.)
    case onDelete(EventID)
    /// `.onMove { from, to in … }`. On a reorder the host dispatches `event` with
    /// `.array([.int])` = `[from₀, from₁, …, to]` (the source offsets then the
    /// destination); the guest reorders its array.
    case onMove(EventID)

    // MARK: Scroll & layout (sweep — scroll/layout modifiers, added at END)
    //
    // These reapply as the real SwiftUI scroll/layout modifiers on-device; each
    // carries pure data (a bool literal, a visibility/axes/behavior name string,
    // or numeric lengths) so it is faithfully reconstructable. The OS-version
    // floor is enforced in the renderer (older OS → no-op, faithful). A form the
    // emitter can't reduce to this data slots instead (demote-safe).

    /// `.scrollDisabled(_:)` (iOS 16+) — a bool literal disabling scrolling.
    case scrollDisabled(Bool)
    /// `.scrollIndicators(_:axes:)` (iOS 16+) — visibility ("automatic"|"visible"|
    /// "hidden"|"never") + axes ("horizontal"|"vertical"|"all").
    case scrollIndicators(String, axes: String)
    /// `.scrollTargetBehavior(_:)` (iOS 17+) — "viewAligned" | "paging".
    case scrollTargetBehavior(String)
    /// `.scrollTargetLayout(isEnabled:)` (iOS 17+) — a bool literal.
    case scrollTargetLayout(Bool)
    /// `.scrollBounceBehavior(_:axes:)` (iOS 16.4+) — behavior ("automatic"|
    /// "always"|"basedOnSize") + axes ("horizontal"|"vertical"|"all").
    case scrollBounceBehavior(String, axes: String)
    /// `.contentMargins([edges,] length[, for:])` (iOS 17+) — edges
    /// ("all"|"top"|...|"horizontal"|"vertical"), a numeric length, and a
    /// placement ("automatic"|"scrollContent"|"scrollIndicators").
    case contentMargins(edges: String, length: Double, placement: String)
    /// `.safeAreaPadding(_:)` / `.safeAreaPadding(_:_:)` (iOS 17+) — edges
    /// ("all"|"top"|...|"horizontal"|"vertical") + an OPTIONAL numeric length
    /// (nil = the system default). An `EdgeInsets` form lowers via `insets`.
    case safeAreaPadding(edges: String, length: Double?, insets: IREdgeInsets?)
    // MARK: Control config — additional built-in styles (styles-views wave)
    //
    // Each carries the built-in named style as a String (parallel to
    // `pickerStyle`/`toggleStyle`/`gaugeStyle`). A custom style STRUCT is a call,
    // not a `.case`, so the engine slots it (the modifier stays native) — the
    // honest boundary. The renderer applies the real SwiftUI style; an
    // unavailable static degrades to no-op.

    /// `.textFieldStyle(_:)` — "automatic"|"plain"|"roundedBorder".
    case textFieldStyle(String)
    /// `.datePickerStyle(_:)` — "automatic"|"compact"|"graphical"|"wheel"|"field"|"stepperField".
    case datePickerStyle(String)
    /// `.groupBoxStyle(_:)` — "automatic" (the only built-in named style).
    case groupBoxStyle(String)
    /// `.controlGroupStyle(_:)` — "automatic"|"navigation"|"compactMenu"|"menu"|"palette".
    case controlGroupStyle(String)
    /// `.disclosureGroupStyle(_:)` — "automatic" (the only built-in named style).
    case disclosureGroupStyle(String)
    /// `.tableStyle(_:)` — "automatic"|"inset"|"bordered".
    case tableStyle(String)

    /// A modifier we recognized syntactically but cannot lower (e.g.
    /// a continuous custom `.gesture(...)`, an arbitrary `.modifier(...)`).
    /// Carries a label for diagnostics; the host ignores it (the un-lowered
    /// behavior is the native-fallback's responsibility).
    case opaque(String)
}

// MARK: - Built-in style enums

/// SwiftUI's built-in `ButtonStyle`s (a custom struct stays `.opaque`).
public enum IRButtonStyle: String, Equatable, Sendable {
    case automatic, bordered, borderedProminent, borderless, plain
}

/// SwiftUI's built-in `ListStyle`s.
public enum IRListStyle: String, Equatable, Sendable {
    case automatic, plain, grouped, insetGrouped, inset, sidebar, bordered
}

// MARK: - Shapes

/// A rounded-corner style (`.circular` / `.continuous`). SwiftUI's default is
/// `.circular`.
public enum IRRoundedCornerStyle: String, Equatable, Sendable {
    case circular, continuous
}

public enum ShapeKind: Equatable, Sendable {
    case rectangle
    case roundedRectangle(cornerRadius: Double)
    case circle
    case ellipse
    case capsule
    /// `UnevenRoundedRectangle(topLeadingRadius:…, …, style:)` (iOS 16.4+). The host
    /// degrades to a `RoundedRectangle` of the max radius on older OSes.
    case unevenRoundedRectangle(topLeading: Double, topTrailing: Double,
                                bottomLeading: Double, bottomTrailing: Double,
                                style: IRRoundedCornerStyle)
    /// `ContainerRelativeShape()` — inherits the container's concentric radius from
    /// the environment (no params).
    case containerRelative
}

// MARK: - Node kinds

public indirect enum NodeKind: Equatable, Sendable {
    // Primitives
    case text(String)
    /// `Text` with a content flag the plain `text(String)` can't carry:
    ///   * `verbatim` → `Text(verbatim:)` (skip the localization lookup),
    ///   * `markdown` → host does `try? AttributedString(markdown:)` (Foundation),
    ///   * `localized` → `Text(LocalizedStringKey(s))` (resolve the shipped
    ///     `.strings`; a missing key shows verbatim — native behavior).
    /// At most one flag is set in practice; the host applies them in that order.
    case styledText(String, verbatim: Bool, markdown: Bool, localized: Bool)
    /// `Text(date, style:)` — a self-ticking date/time/relative/timer label. The
    /// guest emits a `Double` epoch (seconds since 1970); the host rebuilds the
    /// `Date` + a real `Text(_:style:)` that updates itself.
    case dateText(epoch: Double, style: IRDateTextStyle)
    case image(systemName: String)
    /// `Image(systemName:, variableValue:)` (iOS 16+). `variableValue` drives the
    /// SF Symbol's variable rendering (e.g. wifi strength); nil = the plain symbol.
    case symbolImage(systemName: String, variableValue: Double?)
    /// `Image("assetName")` — resolves the shipped Asset Catalog by name (a data
    /// lookup; the bytes are already in the bundle). Promoted from `.opaque`.
    case bundleImage(name: String)
    /// `AsyncImage(url:, scale:)` — the host renders the REAL `AsyncImage` (its own
    /// URLSession loader is in the binary). The default (no content/placeholder)
    /// form; a content/placeholder-closure form stays opaque.
    case asyncImage(url: String, scale: Double?)
    case spacer(minLength: Double?)
    case divider
    case color(ColorRef)
    case shape(ShapeKind)
    /// An INDETERMINATE `ProgressView()` (a spinner). The DETERMINATE
    /// value/total/label form is `determinateProgress` below.
    case progressView
    /// `ProgressView(value:total:) { label }` — a determinate progress bar. `total`
    /// defaults to 1 in SwiftUI; `label` is an optional lowered subtree.
    case determinateProgress(value: Double, total: Double, label: [ViewNode])
    /// `Gauge(value:in:) { label }` (iOS 16+). The host degrades to a determinate
    /// `ProgressView(value:)` on platforms without `Gauge`.
    case gauge(data: IRGaugeData, label: [ViewNode])
    /// `Link(destination:) { label }` — a real `Link` (uses the environment
    /// `openURL`, in the binary). `destination` is the URL string.
    case link(destination: String, label: [ViewNode])
    /// `ShareLink(items:) { label }` — the built-in share sheet (no new
    /// entitlement). `items` are URL/text strings; a custom `label` subtree (a
    /// bare `ShareLink(item:)` with the default label emits an empty `label`).
    case shareLink(items: [String], label: [ViewNode])
    /// `SecureField(placeholder, text: $s)` — clones `textField` (obscured input).
    case secureField(placeholder: String, value: String, event: EventID)
    /// `TextEditor(text: $s)` — a multi-line text input bound to the guest.
    case textEditor(value: String, event: EventID)
    /// `LabeledContent { content } label: { label }` — a label + trailing value,
    /// both lowered subtrees.
    case labeledContent(label: [ViewNode], content: [ViewNode])
    /// `Menu { items } label: { label }` — a pull-down menu; `items` are standard
    /// controls (Buttons auto-wired via the actionID path).
    case menu(label: [ViewNode], items: [ViewNode])

    // Containers
    case vstack(alignment: IRHorizontalAlignment?, spacing: Double?, children: [ViewNode])
    case hstack(alignment: IRVerticalAlignment?, spacing: Double?, children: [ViewNode])
    case zstack(alignment: IRAlignment?, children: [ViewNode])
    case group(children: [ViewNode])
    /// `ForEach` over a literal/marshalled array: the children are the already
    /// unrolled, per-element subtrees (the guest evaluates the loop in WASM).
    case forEach(children: [ViewNode])

    // Containers — IR v2 (more of a real screen rides WASM, granularly patchable).

    /// `ScrollView(axis) { … }`. `axis` defaults to `.vertical` in SwiftUI.
    /// `LazyVStack`/`LazyHStack` are NOT modeled here — the engine maps them to
    /// `vstack`/`hstack` (laziness is a perf hint, not a layout difference for
    /// the rendered tree).
    case scrollView(axis: IRScrollAxis, children: [ViewNode])
    /// `List { … }` (static rows) or `List(items) { … }` (the engine pre-unrolls
    /// the dynamic form's rows like `ForEach`). The host renders a real `List`.
    case list(children: [ViewNode])
    /// `Section { content } header: { … } footer: { … }`. A string-titled
    /// `Section("Title") { … }` lowers `header` to `[N.text("Title")]`; an empty
    /// `header`/`footer` renders no header/footer.
    case section(header: [ViewNode], footer: [ViewNode], content: [ViewNode])
    /// `Form { … }`. The host renders a real `Form` (grouped, inset list).
    case form(children: [ViewNode])
    /// `NavigationStack { … }` (and the legacy `NavigationView`, which the engine
    /// also maps here). The host renders a real `NavigationStack`.
    case navigationStack(children: [ViewNode])

    // Containers — leaf-views + container expansion (A.3).

    /// `LazyVStack`/`LazyHStack` modeled DISTINCTLY from the perf-only
    /// vstack/hstack mapping (so a tree can preserve that it was a lazy stack).
    /// Layout-identical to vstack/hstack for the rendered tree.
    case lazyVStack(alignment: IRHorizontalAlignment?, spacing: Double?, children: [ViewNode])
    case lazyHStack(alignment: IRVerticalAlignment?, spacing: Double?, children: [ViewNode])
    /// `LazyVGrid(columns:)` / `LazyHGrid(rows:)`. `tracks` are the column/row
    /// `IRGridItem`s; the engine pre-unrolls the cells like ForEach into `children`.
    case lazyVGrid(columns: [IRGridItem], spacing: Double?, children: [ViewNode])
    case lazyHGrid(rows: [IRGridItem], spacing: Double?, children: [ViewNode])
    /// `Grid { GridRow { … } }` (iOS 16+; `#available`-guarded; degrades to a VStack
    /// of the rows). `children` are `gridRow` nodes (or arbitrary views).
    case grid(alignment: IRAlignment?, horizontalSpacing: Double?, verticalSpacing: Double?,
              children: [ViewNode])
    /// `GridRow { … }` — a single row inside a `grid`.
    case gridRow(alignment: IRVerticalAlignment?, children: [ViewNode])
    /// `GroupBox { content } label: { label }`. Default style lowers; a custom
    /// `groupBoxStyle` stays native (slot).
    case groupBox(label: [ViewNode], children: [ViewNode])
    /// `DisclosureGroup { content } label: { label }` — UNBOUND (no `isExpanded`
    /// binding; SwiftUI owns the toggle). A bound form is a later host-state task.
    case disclosureGroup(label: [ViewNode], children: [ViewNode])
    /// `ViewThatFits(in:) { candidates }` — candidates recurse; the fit decision is
    /// SwiftUI's (iOS 16+; degrades to the first candidate).
    case viewThatFits(axes: IRAxisSet, children: [ViewNode])
    /// `ControlGroup { content }` (iOS 16+; degrades to an HStack).
    case controlGroup(children: [ViewNode])
    /// `TabView { … }` UNBOUND (no selection binding). `tabs` carry each tab's tag +
    /// `.tabItem` label + content. `style` is the `.tabViewStyle(...)` data flag.
    case tabView(tabs: [IRTab], style: IRTabViewStyle)

    // Interaction
    /// `Button(role:, action:) { label }`. `role` carries the semantic role
    /// (`.destructive`/`.cancel`/nil) so alert/confirmationDialog/context-menu
    /// actions render correctly; the action is the `actionID` (auto-wired host-side).
    case button(actionID: String, role: IRButtonRole?, label: [ViewNode])

    /// `Label { title } icon: { icon }` — the GENERAL form: title + icon are lowered
    /// subtrees so custom title/icon closures recurse. The
    /// `Label("Title", systemImage:)` convenience emits `title: [.text]`,
    /// `icon: [.image(systemName:)]`.
    case label(title: [ViewNode], icon: [ViewNode])

    /// `contextMenu { items }` attached to a content view: the items (standard
    /// controls, Buttons auto-wired via the actionID path) recurse. The host
    /// applies `.contextMenu { … }` to the content; modeled as a node wrapping the
    /// content so the menu travels with it.
    case contextMenu(content: [ViewNode], items: [ViewNode])

    /// A declarative `Path { … }` with concrete scalar commands. The host replays
    /// `commands` into a real `Path` (a `Shape`). Fill/stroke are MODIFIERS (another
    /// lane) — a bare `path` renders as the default foreground-filled shape.
    case path(commands: [IRPathCommand])

    // Stateful controls (the INTERACTIVE additions — Breakthrough #5).
    // Each carries the control's CURRENT value (read from the guest's state when
    // the tree was emitted) plus the `EventID` the host dispatches on change.
    // The native renderer wires the real SwiftUI control's two-way `Binding` to
    // send that event back into the guest's `dispatch`.

    /// `Toggle(label, isOn: $flag)`. `value` is the current Bool; on change the
    /// host dispatches `event` with `.bool(newValue)`.
    case toggle(label: [ViewNode], value: Bool, event: EventID)
    /// `Slider(value: $x, in: lo...hi, step:)`. `value` is current; on change the
    /// host dispatches `event` with `.double(newValue)`.
    case slider(value: Double, min: Double, max: Double, step: Double?, event: EventID)
    /// `Stepper(label, value: $n, in:…, step:)`. Integer counter. On +/- the host
    /// dispatches `event` with `.int(newValue)`.
    case stepper(label: [ViewNode], value: Int, min: Int?, max: Int?, step: Int, event: EventID)
    /// `TextField(placeholder, text: $s)`. `value` is current text; on edit the
    /// host dispatches `event` with `.string(newValue)`.
    case textField(placeholder: String, value: String, event: EventID)

    // Host-state controls (B — selection / navigation). Each owns a real SwiftUI
    // selection/path the SDK binds: the binding's GET returns the guest-emitted
    // current value, its SET dispatches the event back into the guest's `dispatch`.

    /// `Picker(selection: $sel) { options } label: { label }`. `selection` is the
    /// current tag (typed `IRValue` — `.int`/`.string`); `kind` tells the host which
    /// `Binding<Int>`/`Binding<String>` to build. On pick the host dispatches `event`
    /// with the chosen option's tag value. `pickerStyle` rides as a normal modifier.
    case picker(label: [ViewNode], selection: IRValue, kind: IRSelectionKind,
                options: [IRPickerOption], event: EventID)
    /// `DatePicker(label, selection: $date[, in:…], displayedComponents:)`. The date
    /// crosses as an epoch `Double` (seconds since 1970); on change the host
    /// dispatches `event` with `.double(epoch)`. `components` is
    /// "date"|"hourAndMinute"|"dateAndTime". `min`/`max` are optional epoch bounds.
    case datePicker(label: [ViewNode], epoch: Double, components: String,
                    minEpoch: Double?, maxEpoch: Double?, event: EventID)
    /// `ColorPicker(label, selection: $color[, supportsOpacity:])`. The color crosses
    /// as RGBA components (`IRColor`); on change the host dispatches `event` with
    /// `.array([.double r,.double g,.double b,.double a])` (the guest reconstructs).
    case colorPicker(label: [ViewNode], color: IRColor, supportsOpacity: Bool, event: EventID)

    /// `NavigationLink(destination:) { label }` — the EAGER form: SwiftUI owns
    /// push/pop, both subtrees recurse. (The value-based `NavigationLink(value:)` +
    /// `NavigationStack(path:)` path form is `navigationStackPath` below.)
    case navigationLink(destination: [ViewNode], label: [ViewNode])
    /// `NavigationStack(path: $path) { root }` + value-based links pushing onto it.
    /// The SDK owns `@State path:[String]` (the pushed value tokens); `path` is the
    /// current token list (emit-time). `destinations` maps a pushed token's typeTag
    /// to its lowered destination body; on a push/pop the host dispatches `event`
    /// with the new `.array([.string])` path. Needs `IRValue.array`.
    case navigationStackPath(path: [String], root: [ViewNode],
                             destinations: [IRNavDestination], event: EventID)

    /// `DisclosureGroup(isExpanded: $flag) { content } label: { label }` — the BOUND
    /// form. `isExpanded` is the current Bool; on toggle the host dispatches `event`
    /// with `.bool`. (The unbound form is `disclosureGroup`.)
    case boundDisclosureGroup(label: [ViewNode], isExpanded: Bool, content: [ViewNode], event: EventID)
    /// `Section(isExpanded: $flag) { content } header: { header }` (iOS 17+) — the
    /// BOUND-expansion form. Degrades to a plain `Section` where unavailable.
    case boundSection(header: [ViewNode], isExpanded: Bool, content: [ViewNode], event: EventID)
    /// `TabView(selection: $sel) { tabs }` — the BOUND form. `selection` is the
    /// current tag (typed); `kind` is its projection. On a tab tap the host
    /// dispatches `event` with the tapped tab's tag value.
    case boundTabView(selection: IRValue, kind: IRSelectionKind,
                      tabs: [IRTab], style: IRTabViewStyle, event: EventID)
    /// `EditButton()` — a real stdlib view toggling the SDK-owned `EditMode`
    /// environment state. No payload (SwiftUI owns it once placed in a List).
    case editButton

    /// `GeometryReader { proxy in <body> }` — promoted from slot-native to
    /// host-state (C). The SDK renders a REAL `GeometryReader { proxy in … }`
    /// wrapper; on each layout it injects `proxy.size.width`/`.height` (and
    /// `.frame(in:.local)` origin) as RESERVED marshalled inputs
    /// (`__geo_width`/`__geo_height`/`__geo_minX`/`__geo_minY`) and re-evaluates
    /// the lowered child body — which READS those reserved inputs like any `@State`
    /// scalar. `children` is the lowered body (built with the proxy member accesses
    /// rewritten to the reserved input identifiers by the engine). A `proxy` use the
    /// engine can't map (`proxy[anchor]`, `proxy.safeAreaInsets`, `proxy.size` whole)
    /// → the whole GeometryReader stays a native slot. `id` is a content-stable token
    /// so the SDK host wrapper can re-locate THIS reader in the re-emitted tree.
    case geometryReader(id: String, children: [ViewNode])

    /// `Canvas { ctx, size in <draws> }` — a serialized drawing-op replay (C). The
    /// SDK renders a REAL `Canvas` and replays `ops` via the in-binary
    /// `GraphicsContext` (no native draw code ships). The COMMON DECLARATIVE draw
    /// forms (`ctx.fill`/`ctx.stroke`/`ctx.draw(Text,at:)`) serialize; an imperative/
    /// computed draw demotes the whole Canvas to a native slot. The canvas size is
    /// injected as reserved `__canvas_width`/`__canvas_height` inputs (like the geo
    /// reader), so size-relative coords the guest computed ride through. (Engine note:
    /// the engine currently SLOTS Canvas — faithfully parsing imperative
    /// `GraphicsContext` closures is out of the demote-safe budget; this node + the
    /// SDK replay are proven + round-trip for hand-written/future emission.)
    case canvas(ops: [IRDrawOp])

    /// A node that referenced something non-lowerable (a custom
    /// `UIViewRepresentable`, an environment-dependent expression, etc.). The
    /// host renders this from a native side table keyed by `id`; `label`
    /// describes what it was for diagnostics + the measurement.
    case opaque(id: String, label: String)
}

// MARK: - ViewNode

public struct ViewNode: Equatable, Sendable {
    public var kind: NodeKind
    public var modifiers: [Modifier]

    public init(_ kind: NodeKind, modifiers: [Modifier] = []) {
        self.kind = kind
        self.modifiers = modifiers
    }

    /// Append a modifier (mirrors SwiftUI's chaining; returns a new node).
    public func with(_ m: Modifier) -> ViewNode {
        var copy = self
        copy.modifiers.append(m)
        return copy
    }
}

// MARK: - Tree statistics (used by both the guest self-report and host tests)

extension ViewNode {
    /// Every descendant subtree to recurse into for tree statistics: the
    /// `kind`-level children PLUS any subtrees a MODIFIER carries (a
    /// `.background { … }`/`.overlay { … }`/`.mask { … }`/`.safeAreaInset { … }`
    /// content). Render walks `kind` children directly and modifier content via
    /// the modifier arm, but the stats must see both so coverage stays honest.
    private var allDescendantSubtrees: [ViewNode] {
        var out = childNodes
        for m in modifiers { out.append(contentsOf: m.contentNodes) }
        return out
    }

    /// Total nodes in the subtree (this node + all descendants, incl. modifier content).
    public var nodeCount: Int {
        1 + allDescendantSubtrees.reduce(0) { $0 + $1.nodeCount }
    }

    /// Total modifiers across the subtree.
    public var modifierCount: Int {
        modifiers.count + allDescendantSubtrees.reduce(0) { $0 + $1.modifierCount }
    }

    /// Count of `.opaque` nodes (native-fallback slots) in the subtree.
    public var opaqueNodeCount: Int {
        let here: Int
        if case .opaque = kind { here = 1 } else { here = 0 }
        return here + allDescendantSubtrees.reduce(0) { $0 + $1.opaqueNodeCount }
    }

    /// Count of `.opaque` modifiers across the subtree.
    public var opaqueModifierCount: Int {
        let here = modifiers.reduce(0) { acc, m in
            if case .opaque = m { return acc + 1 } else { return acc }
        }
        return here + allDescendantSubtrees.reduce(0) { $0 + $1.opaqueModifierCount }
    }

    /// Direct children, regardless of container kind.
    public var childNodes: [ViewNode] {
        switch kind {
        case .vstack(_, _, let c), .hstack(_, _, let c),
             .group(let c), .forEach(let c):
            return c
        case .zstack(_, let c):
            return c
        case .scrollView(_, let c), .list(let c), .form(let c),
             .navigationStack(let c):
            return c
        case .lazyVStack(_, _, let c), .lazyHStack(_, _, let c),
             .lazyVGrid(_, _, let c), .lazyHGrid(_, _, let c),
             .controlGroup(let c), .viewThatFits(_, let c),
             .grid(_, _, _, let c), .gridRow(_, let c):
            return c
        case .section(let header, let footer, let content):
            return header + content + footer
        case .groupBox(let label, let content), .disclosureGroup(let label, let content),
             .labeledContent(let label, let content), .menu(let label, let content):
            return label + content
        case .contextMenu(let content, let items):
            return content + items
        case .tabView(let tabs, _):
            return tabs.flatMap { $0.tabItem + $0.content }
        case .boundTabView(_, _, let tabs, _, _):
            return tabs.flatMap { $0.tabItem + $0.content }
        case .button(_, _, let label):
            return label
        case .label(let title, let icon):
            return title + icon
        case .toggle(let label, _, _):
            return label
        case .stepper(let label, _, _, _, _, _):
            return label
        case .determinateProgress(_, _, let label), .gauge(_, let label),
             .link(_, let label), .shareLink(_, let label):
            return label
        // Host-state controls — their label/option/content subtrees recurse.
        case .picker(let label, _, _, let options, _):
            return label + options.flatMap { $0.label }
        case .datePicker(let label, _, _, _, _, _), .colorPicker(let label, _, _, _):
            return label
        case .navigationLink(let destination, let label):
            return destination + label
        case .navigationStackPath(_, let root, let destinations, _):
            return root + destinations.flatMap { $0.body }
        case .boundDisclosureGroup(let label, _, let content, _):
            return label + content
        case .boundSection(let header, _, let content, _):
            return header + content
        case .geometryReader(_, let children):
            return children
        case .canvas(let ops):
            // A Canvas's only recursive subtrees are its `drawText` Text leaves.
            return ops.flatMap { op -> [ViewNode] in
                if case .drawText(let text, _, _, _) = op { return text }
                return []
            }
        case .text, .styledText, .dateText, .image, .symbolImage, .bundleImage,
             .asyncImage, .spacer, .divider, .color, .shape, .progressView,
             .opaque, .slider, .textField, .secureField, .textEditor, .path,
             .editButton:
            return []
        }
    }
}

extension Modifier {
    /// The recursive content subtree a modifier carries, if any (a
    /// `.background`/`.overlay`/`.mask`/`.safeAreaInset` view-builder, OR a
    /// host-state presentation/destination content subtree). Empty for every
    /// value-only modifier.
    public var contentNodes: [ViewNode] {
        switch self {
        case .backgroundContent(_, let c), .overlayContent(_, let c),
             .mask(_, let c), .safeAreaInset(_, _, _, let c):
            return c
        // Host-state presentation/navigation content subtrees (so coverage + the
        // drift-safe stats see the sheet/alert/destination bodies).
        case .sheet(_, _, let c, _), .sheetItem(_, _, let c, _),
             .fullScreenCover(_, _, let c, _), .popover(_, _, let c, _),
             .navigationDestinationBool(_, _, let c, _):
            return c
        case .alert(_, _, _, let actions, let message, _),
             .confirmationDialog(_, _, _, _, let actions, let message, _):
            return actions + message
        case .toolbar(let items):
            return items.flatMap { $0.content }
        default:
            return []
        }
    }
}

// MARK: - Codable (host / T2 only; Embedded Swift has no Codable)
// Co-located here so the compiler auto-synthesizes init(from:)/encode(to:).
#if !FRONTIER_EMBEDDED
extension IRColor: Codable {}
extension ColorRef: Codable {}
extension EventID: Codable {}
extension IRValue: Codable {}
extension IRFont: Codable {}
extension IRFont.Weight: Codable {}
extension IRFont.Design: Codable {}
extension IRFont.TextStyle: Codable {}
extension IREdgeInsets: Codable {}
extension IRAlignment: Codable {}
extension IRHorizontalAlignment: Codable {}
extension IRVerticalAlignment: Codable {}
extension IRTextAlignment: Codable {}
extension IRScrollAxis: Codable {}
extension IRLength: Codable {}
extension IRUnitPoint: Codable {}
extension IRGradientStop: Codable {}
extension IRGradient: Codable {}
extension IRMaterial: Codable {}
extension IRStrokeStyle: Codable {}
extension IRShadowStyle: Codable {}
extension IRShapeStyle: Codable {}
extension IRContentMode: Codable {}
extension IRBlendMode: Codable {}
extension IRAnimation: Codable {}
extension IRTransition: Codable {}
extension IRButtonStyle: Codable {}
extension IRListStyle: Codable {}
extension IRDateTextStyle: Codable {}
extension IRGaugeData: Codable {}
extension IRGridItemSize: Codable {}
extension IRGridItem: Codable {}
extension IRAxisSet: Codable {}
extension IRTab: Codable {}
extension IRTabViewStyle: Codable {}
extension IRButtonRole: Codable {}
extension IRPickerOption: Codable {}
extension IRSelectionKind: Codable {}
extension IRNavDestination: Codable {}
extension IRToolbarItem: Codable {}
extension IRDrawOp: Codable {}
extension IRPathCommand: Codable {}
extension IRRoundedCornerStyle: Codable {}
extension Modifier: Codable {}
extension ShapeKind: Codable {}
extension NodeKind: Codable {}
extension ViewNode: Codable {}
#endif
