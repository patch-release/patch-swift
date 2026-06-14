// UIKitNode — the serializable IR for a (declarative) UIKit view construction.
// =============================================================================
// This is the UIKit analogue of `ViewNode` (the SwiftUI IR). It is the SINGLE
// shared contract between the WASM *guest* (which builds + serializes a
// `UIKitNode` tree inside the sandbox) and the native *host* renderer (which
// reconstitutes REAL UIKit — `UILabel`/`UIButton`/`UIImageView`/`UIStackView`/
// `UIView` + Auto Layout — from the tree). Like `ViewNode` it is pure
// `Equatable`/`Sendable` value types that are `Codable` only OFF the Embedded
// tier (the `#if !FRONTIER_EMBEDDED` pattern), so it compiles unchanged into a
// `wasm32-unknown-wasip1` (or embedded) module AND into the host SDK.
//
// It lives in the SAME `ViewNodeIR` module as `ViewNode` ON PURPOSE: it REUSES
// the shared value types (`IRColor`/`ColorRef`/`IRFont`/`IREdgeInsets`/`EventID`/
// `IRTextAlignment`) without re-declaring them — exactly how the SwiftUI IR
// carries them. Because the canonical IR files carry NO `import`, a guest copy
// is byte-identical to the canonical source (the drift guard asserts this), and
// the shared types are already present in the guest because the SwiftUI
// `ViewNode` copy ships them.
//
// Design notes
// ------------
// * A `UIKitNode` is a `kind` (the view to construct) PLUS a uniform set of
//   per-node *view properties* (`UIKitViewProps`) PLUS its Auto Layout
//   `constraints`. Unlike SwiftUI's ordered-modifier model, UIKit view
//   construction is imperative-but-flat: you make a view, set properties, add
//   subviews, and activate constraints. So the IR folds the common UIView
//   properties into a struct rather than an ordered list — order is NOT
//   semantically meaningful for "set backgroundColor; set cornerRadius".
// * Anything we cannot lower becomes a `.customSlot(id:)` node (a native leaf
//   the host fills from a side table) — the UIKit analogue of `ViewNode.opaque`.
//   This makes the lowering total: a tree never fails to lower; the
//   un-lowerable bits degrade to a native `UIView`.
// * Auto Layout is modeled as the common `NSLayoutConstraint.activate` grammar:
//   each node carries `[IRConstraint]`, each an anchor-relation-anchor form with
//   a multiplier/constant/priority — enough for both the anchor-based DSL
//   (`view.leadingAnchor.constraint(equalTo:…)`) and the
//   `NSLayoutConstraint(item:attribute:…)` form.

// MARK: - Auto Layout grammar

/// One layout attribute on a view — the anchor/`NSLayoutConstraint.Attribute`
/// vocabulary. Mirrored by raw name so it survives the boundary without UIKit.
public enum IRAnchor: String, Equatable, Sendable {
    case leading, trailing, top, bottom, left, right
    case width, height
    case centerX, centerY
    case firstBaseline, lastBaseline
}

/// The relation of a constraint (`NSLayoutConstraint.Relation`).
public enum IRConstraintRelation: String, Equatable, Sendable {
    case eq          // .equal
    case ge          // .greaterThanOrEqual
    case le          // .lessThanOrEqual
}

/// What the *second* side of a constraint targets. The host resolves this to a
/// real view (or its `safeAreaLayoutGuide`) and the second anchor:
///   * `.superview`  — the node's parent view,
///   * `.safeArea`   — the parent's `safeAreaLayoutGuide`,
///   * `.selfView`   — the node itself (e.g. `width == 2 * height` on one view),
///   * `.sibling(id)`— another node addressed by its `UIKitViewProps.id`.
/// A `width`/`height` constraint with NO second item (a constant size) omits the
/// ref entirely (`second == nil` on `IRConstraint`).
public enum IRAnchorTarget: Equatable, Sendable {
    case superview
    case safeArea
    case selfView
    case sibling(id: String)
}

/// The second side of a constraint: which view (`target`) and which `anchor` on
/// it. e.g. `child.leadingAnchor == parent.leadingAnchor` is
/// `IRAnchorRef(target: .superview, anchor: .leading)`.
public struct IRAnchorRef: Equatable, Sendable {
    public var target: IRAnchorTarget
    public var anchor: IRAnchor
    public init(target: IRAnchorTarget, anchor: IRAnchor) {
        self.target = target; self.anchor = anchor
    }
}

/// A single `NSLayoutConstraint` as pure data, covering the common grammar:
///   `first  (relation)  multiplier * second + constant   @priority`
/// * `first` is the anchor on THIS node.
/// * `second` is the other side; `nil` for a constant width/height
///   (`view.widthAnchor.constraint(equalToConstant: constant)`).
/// * `multiplier`/`constant` default to the `NSLayoutConstraint` defaults (1, 0).
/// * `priority` is the optional `UILayoutPriority` rawValue (nil = `.required`).
public struct IRConstraint: Equatable, Sendable {
    public var first: IRAnchor
    public var relation: IRConstraintRelation
    public var second: IRAnchorRef?
    public var multiplier: Double
    public var constant: Double
    public var priority: Double?
    public init(first: IRAnchor,
                relation: IRConstraintRelation = .eq,
                second: IRAnchorRef? = nil,
                multiplier: Double = 1,
                constant: Double = 0,
                priority: Double? = nil) {
        self.first = first
        self.relation = relation
        self.second = second
        self.multiplier = multiplier
        self.constant = constant
        self.priority = priority
    }
}

// MARK: - UIKit enums (mirrored by raw name)

/// `UIStackView.Axis`.
public enum IRStackAxis: String, Equatable, Sendable {
    case horizontal, vertical
}

/// `UIStackView.Alignment`.
public enum IRStackAlignment: String, Equatable, Sendable {
    case fill, leading, firstBaseline, center, trailing, lastBaseline
    // NB: `top`/`bottom` are the horizontal-axis aliases of leading/trailing in
    // UIKit's enum; we keep the canonical six. The host maps top→leading,
    // bottom→trailing for a horizontal stack at render time if needed.
}

/// `UIStackView.Distribution`.
public enum IRStackDistribution: String, Equatable, Sendable {
    case fill, fillEqually, fillProportionally, equalSpacing, equalCentering
}

/// `UIView.ContentMode` (the common subset used by `UIImageView`).
public enum IRUIContentMode: String, Equatable, Sendable {
    case scaleToFill, scaleAspectFit, scaleAspectFill, center
    case top, bottom, left, right
    case topLeft, topRight, bottomLeft, bottomRight, redraw
}

/// `NSTextAlignment` for a `UILabel`. (Distinct from SwiftUI's
/// `IRTextAlignment`, which only has leading/center/trailing — UIKit adds
/// justified/natural.)
public enum IRUITextAlignment: String, Equatable, Sendable {
    case left, center, right, justified, natural
}

/// The image source for a `UIImageView`: an SF Symbol (`UIImage(systemName:)`)
/// or an Asset-Catalog image (`UIImage(named:)`). The bytes for `.assetName`
/// are already in the signed app bundle (a name lookup, like the SwiftUI
/// `bundleImage`).
public enum IRImageRef: Equatable, Sendable {
    case systemName(String)
    case assetName(String)
}

// MARK: - Per-node view properties

/// The common `UIView` properties carried on EVERY node (the UIKit analogue of
/// the most-used cross-cutting SwiftUI modifiers). All optional — `nil` means
/// "leave the platform default". `id` is the node's stable identifier used to
/// target it from a sibling's constraint (`IRAnchorTarget.sibling(id:)`); the
/// host also applies it as `accessibilityIdentifier` when
/// `accessibilityIdentifier` is itself nil (so a sibling-addressable view is
/// still introspectable), but an explicit `accessibilityIdentifier` wins.
public struct UIKitViewProps: Equatable, Sendable {
    /// A stable identifier for sibling-constraint targeting. Empty = anonymous.
    public var id: String
    public var backgroundColor: ColorRef?
    public var cornerRadius: Double?
    public var clipsToBounds: Bool?
    public var alpha: Double?
    public var isHidden: Bool?
    public var tintColor: ColorRef?
    public var accessibilityIdentifier: String?
    public init(id: String = "",
                backgroundColor: ColorRef? = nil,
                cornerRadius: Double? = nil,
                clipsToBounds: Bool? = nil,
                alpha: Double? = nil,
                isHidden: Bool? = nil,
                tintColor: ColorRef? = nil,
                accessibilityIdentifier: String? = nil) {
        self.id = id
        self.backgroundColor = backgroundColor
        self.cornerRadius = cornerRadius
        self.clipsToBounds = clipsToBounds
        self.alpha = alpha
        self.isHidden = isHidden
        self.tintColor = tintColor
        self.accessibilityIdentifier = accessibilityIdentifier
    }
}

// MARK: - Node kinds

public indirect enum UIKitNodeKind: Equatable, Sendable {
    /// `UILabel` — `text`, optional `font`/`textColor`/`numberOfLines`/
    /// `textAlignment`. (`numberOfLines == 0` is UIKit's "unlimited".)
    case label(text: String, font: IRFont?, textColor: ColorRef?,
               numberOfLines: Int?, alignment: IRUITextAlignment?)
    /// `UIButton` — a system button with `title` for `.normal`, optional
    /// `titleColor`/`font`, and an `action` `EventID` wired to a dispatcher
    /// trampoline (`addTarget`) by the host.
    case button(title: String, titleColor: ColorRef?, font: IRFont?, action: EventID)
    /// `UIImageView` — `image` (SF Symbol or asset), optional `tintColor`/
    /// `contentMode`.
    case imageView(image: IRImageRef, tintColor: ColorRef?, contentMode: IRUIContentMode?)
    /// `UIStackView` — `axis`, optional `spacing`/`alignment`/`distribution`, and
    /// `arranged` subviews (added via `addArrangedSubview`).
    case stackView(axis: IRStackAxis, spacing: Double?, alignment: IRStackAlignment?,
                   distribution: IRStackDistribution?, arranged: [UIKitNode])
    /// A plain `UIView` container — `children` are added via `addSubview` (NOT
    /// arranged); positioning is via each child's `constraints`.
    case containerView(children: [UIKitNode])
    /// `UISwitch` — `isOn` current value; on `.valueChanged` the host dispatches
    /// `event` with `.bool(newValue)`. (Cheap stateful control, mirrors the
    /// SwiftUI `toggle`.)
    case switchControl(isOn: Bool, event: EventID)
    /// `UISlider` — `value` in `min...max`; on `.valueChanged` the host
    /// dispatches `event` with `.double(newValue)`.
    case uiSlider(value: Double, min: Double, max: Double, event: EventID)
    /// `UITextField` — `text` + `placeholder`; on `.editingChanged` the host
    /// dispatches `event` with `.string(newValue)`.
    case uiTextField(text: String, placeholder: String, event: EventID)
    /// A native leaf the host fills from a side table keyed by `id` (the UIKit
    /// analogue of `ViewNode.opaque`). `label` describes what it was for
    /// diagnostics. This is the escape-hatch that keeps lowering total.
    case customSlot(id: String, label: String)
}

// MARK: - UIKitNode

public struct UIKitNode: Equatable, Sendable {
    public var kind: UIKitNodeKind
    /// The common `UIView` properties (background/corner radius/alpha/…). Folded
    /// into a struct (not an ordered list) because UIKit property-setting order
    /// is not semantically meaningful.
    public var props: UIKitViewProps
    /// The Auto Layout constraints rooted on THIS node (resolved + activated by
    /// the host against the real view graph).
    public var constraints: [IRConstraint]

    public init(_ kind: UIKitNodeKind,
                props: UIKitViewProps = UIKitViewProps(),
                constraints: [IRConstraint] = []) {
        self.kind = kind
        self.props = props
        self.constraints = constraints
    }

    /// Append a constraint (chainable; returns a new node).
    public func constrained(_ c: IRConstraint) -> UIKitNode {
        var copy = self
        copy.constraints.append(c)
        return copy
    }

    /// Replace the view props (chainable; returns a new node).
    public func withProps(_ p: UIKitViewProps) -> UIKitNode {
        var copy = self
        copy.props = p
        return copy
    }
}

// MARK: - The emission envelope (mirrors BodyEmission for the SwiftUI IR)

/// The root payload a UIKit guest returns across the boundary: the `root`
/// `UIKitNode` plus optional coverage stats. Mirrors `BodyEmission` so the host
/// decodes a UIKit tree exactly as it decodes a SwiftUI one.
public struct UIKitEmission: Equatable, Sendable {
    public var root: UIKitNode
    public var coverage: UIKitCoverage?
    public init(root: UIKitNode, coverage: UIKitCoverage? = nil) {
        self.root = root; self.coverage = coverage
    }
}

/// Self-reported lowering coverage for a UIKit tree (how much rode WASM vs how
/// much degraded to native `.customSlot`s). Parallels the SwiftUI coverage.
public struct UIKitCoverage: Equatable, Sendable {
    public var totalNodes: Int
    public var slotNodes: Int
    public var totalConstraints: Int
    public init(totalNodes: Int, slotNodes: Int, totalConstraints: Int) {
        self.totalNodes = totalNodes
        self.slotNodes = slotNodes
        self.totalConstraints = totalConstraints
    }
}

// MARK: - Tree statistics (guest self-report + host tests)

extension UIKitNode {
    /// Direct children regardless of container kind.
    public var childNodes: [UIKitNode] {
        switch kind {
        case .stackView(_, _, _, _, let arranged):
            return arranged
        case .containerView(let children):
            return children
        case .label, .button, .imageView, .switchControl, .uiSlider,
             .uiTextField, .customSlot:
            return []
        }
    }

    /// Total nodes in the subtree (this node + all descendants).
    public var nodeCount: Int {
        1 + childNodes.reduce(0) { $0 + $1.nodeCount }
    }

    /// Count of `.customSlot` nodes (native-fallback leaves) in the subtree.
    public var slotNodeCount: Int {
        let here: Int
        if case .customSlot = kind { here = 1 } else { here = 0 }
        return here + childNodes.reduce(0) { $0 + $1.slotNodeCount }
    }

    /// Total constraints across the subtree.
    public var constraintCount: Int {
        constraints.count + childNodes.reduce(0) { $0 + $1.constraintCount }
    }
}

// MARK: - Codable (host / T2 only; Embedded Swift has no Codable)
// Co-located here so the compiler auto-synthesizes init(from:)/encode(to:).
// Mirrors the ViewNode.swift strategy. The shared value types (IRColor/ColorRef/
// IRFont/IREdgeInsets/EventID/IRValue) already conform via ViewNode.swift's
// extensions in this same module, so they are NOT re-declared here.
#if !FRONTIER_EMBEDDED
extension IRAnchor: Codable {}
extension IRConstraintRelation: Codable {}
extension IRAnchorTarget: Codable {}
extension IRAnchorRef: Codable {}
extension IRConstraint: Codable {}
extension IRStackAxis: Codable {}
extension IRStackAlignment: Codable {}
extension IRStackDistribution: Codable {}
extension IRUIContentMode: Codable {}
extension IRUITextAlignment: Codable {}
extension IRImageRef: Codable {}
extension UIKitViewProps: Codable {}
extension UIKitNodeKind: Codable {}
extension UIKitNode: Codable {}
extension UIKitCoverage: Codable {}
extension UIKitEmission: Codable {}
#endif
