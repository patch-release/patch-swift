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
    /// A modifier we recognized syntactically but cannot lower (e.g.
    /// `.animation`, a continuous `.gesture(DragGesture())`, an arbitrary
    /// `.modifier(...)`). Carries a label for diagnostics; the host ignores it
    /// (the un-lowered behavior is the native-fallback's responsibility).
    case opaque(String)
}

// MARK: - Shapes

public enum ShapeKind: Equatable, Sendable {
    case rectangle
    case roundedRectangle(cornerRadius: Double)
    case circle
    case ellipse
    case capsule
}

// MARK: - Node kinds

public indirect enum NodeKind: Equatable, Sendable {
    // Primitives
    case text(String)
    case image(systemName: String)
    case spacer(minLength: Double?)
    case divider
    case color(ColorRef)
    case shape(ShapeKind)

    // Containers
    case vstack(alignment: IRHorizontalAlignment?, spacing: Double?, children: [ViewNode])
    case hstack(alignment: IRVerticalAlignment?, spacing: Double?, children: [ViewNode])
    case zstack(alignment: IRAlignment?, children: [ViewNode])
    case group(children: [ViewNode])
    /// `ForEach` over a literal/marshalled array: the children are the already
    /// unrolled, per-element subtrees (the guest evaluates the loop in WASM).
    case forEach(children: [ViewNode])

    // Interaction
    case button(actionID: String, label: [ViewNode])

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
    /// Total nodes in the subtree (this node + all descendants).
    public var nodeCount: Int {
        1 + childNodes.reduce(0) { $0 + $1.nodeCount }
    }

    /// Total modifiers across the subtree.
    public var modifierCount: Int {
        modifiers.count + childNodes.reduce(0) { $0 + $1.modifierCount }
    }

    /// Count of `.opaque` nodes (native-fallback slots) in the subtree.
    public var opaqueNodeCount: Int {
        let here: Int
        if case .opaque = kind { here = 1 } else { here = 0 }
        return here + childNodes.reduce(0) { $0 + $1.opaqueNodeCount }
    }

    /// Count of `.opaque` modifiers across the subtree.
    public var opaqueModifierCount: Int {
        let here = modifiers.reduce(0) { acc, m in
            if case .opaque = m { return acc + 1 } else { return acc }
        }
        return here + childNodes.reduce(0) { $0 + $1.opaqueModifierCount }
    }

    /// Direct children, regardless of container kind.
    public var childNodes: [ViewNode] {
        switch kind {
        case .vstack(_, _, let c), .hstack(_, _, let c),
             .group(let c), .forEach(let c):
            return c
        case .zstack(_, let c):
            return c
        case .button(_, let label):
            return label
        case .toggle(let label, _, _):
            return label
        case .stepper(let label, _, _, _, _, _):
            return label
        case .text, .image, .spacer, .divider, .color, .shape, .opaque,
             .slider, .textField:
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
extension Modifier: Codable {}
extension ShapeKind: Codable {}
extension NodeKind: Codable {}
extension ViewNode: Codable {}
#endif
