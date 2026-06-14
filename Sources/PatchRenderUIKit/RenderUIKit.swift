// RenderUIKit.swift — the native SDK renderer: UIKitNode IR -> REAL UIKit.
// =========================================================================
// This is the UIKit analogue of `PatchRender/Render.swift` (the SwiftUI host
// renderer). The WASM guest builds a `UIKitNode` tree and serializes it across
// the boundary; this renderer reconstitutes REAL UIKit from that tree —
// real `UILabel`/`UIButton`/`UIImageView`/`UIStackView`/`UIView`, with the view
// properties set, subviews added (`addSubview`/`addArrangedSubview`), and the
// `[IRConstraint]` resolved against the real view graph and
// `NSLayoutConstraint.activate`d.
//
// UIKit exists only on the iOS/tvOS/visionOS family — NOT on macOS or Linux —
// so the ENTIRE renderer is `#if canImport(UIKit)`-guarded. On a platform
// without UIKit this module compiles to a no-op (an empty enum marker), so the
// SDK builds everywhere; the renderer runs on device (and in the on-device E2E).
//
// Button / control callbacks: a node's `action`/`event` is an `EventID`. The
// host owns a side table (`UIKitDispatcher`) that forwards the event into the
// guest's `dispatch` (the interactive loop is a later wave — a stub sink is a
// valid Dispatcher today). The renderer installs a target/action trampoline
// (`UIKitActionTrampoline`) that calls the dispatcher; value-bearing controls
// (`UISwitch`/`UISlider`/`UITextField`) ship the new value as the right
// `IRValue`. A `customSlot(id)` pulls a native `UIView` from a side table
// (`UIKitSlotTable`) — the UIKit analogue of the SwiftUI `OpaqueTable`.

#if canImport(UIKit)
import UIKit
import PatchViewIR

// MARK: - Host wiring tables

/// Maps a `.customSlot` node's id to a real native `UIView` the host supplies
/// for the bits that don't lower (custom subclasses, `MKMapView`, gesture-driven
/// views, …). If no view is registered, a labeled placeholder renders (when
/// `showSlotStubs` is on) so the gap is visible rather than silent.
public final class UIKitSlotTable {
    private var views: [String: UIView] = [:]
    public init() {}
    public func set(_ id: String, _ view: UIView) { views[id] = view }
    public func view(for id: String) -> UIView? { views[id] }
}

/// The sink a control fires when the user changes it: it carries the `EventID`
/// (which UPDATE branch in the guest runs) and the new `IRValue`. The host
/// forwards this to the guest's `dispatch`, the guest mutates state in WASM and
/// re-emits, and the host re-renders. The guest dispatch loop is a later wave;
/// a no-op sink keeps controls rendering but inert (read-only) today.
@MainActor
public final class UIKitDispatcher {
    public typealias Sink = @MainActor (EventID, IRValue) -> Void
    private let sink: Sink
    public init(_ sink: @escaping Sink) { self.sink = sink }
    public func send(_ event: EventID, _ value: IRValue) { sink(event, value) }
}

/// The target/action trampoline a `UIControl` (`UIButton`/`UISwitch`/`UISlider`/
/// `UITextField`) `addTarget`s. It captures the node's `EventID` + how to read
/// the control's current value, and forwards to the `UIKitDispatcher` on the
/// control event. Held alive by the rendered view (associated-object) so the
/// target isn't deallocated out from under UIKit's weak target reference.
///
/// Deliberately NOT `@MainActor`-isolated: the `@objc` selector UIKit invokes
/// must be exposed to the ObjC runtime as a plain method (a `@MainActor`-isolated
/// `@objc` method is bridged with an actor hop that `sendActions` / `objc_msgSend`
/// does not perform, so the selector silently no-ops). Control events always
/// arrive on the main thread, so reading the control + forwarding to the
/// (`@MainActor`) dispatcher is safe; we assume main-actor isolation explicitly.
final class UIKitActionTrampoline: NSObject {
    private let event: EventID
    private let dispatcher: UIKitDispatcher?
    /// Reads the new value off the firing control (e.g. `UISwitch.isOn`). For a
    /// bare button this returns `.none`.
    private let readValue: @MainActor (UIControl) -> IRValue
    init(event: EventID, dispatcher: UIKitDispatcher?,
         readValue: @escaping @MainActor @Sendable (UIControl) -> IRValue) {
        self.event = event
        self.dispatcher = dispatcher
        self.readValue = readValue
    }
    @objc func fire(_ sender: UIControl) {
        // UIControl actions are delivered on the main thread; assume it so we can
        // touch the @MainActor dispatcher + read the control's value. Capture the
        // stored closures/refs into locals first so the main-actor closure does
        // NOT capture `self` (a nonisolated NSObject) — which Swift 6 flags as a
        // potential race.
        let event = self.event
        let dispatcher = self.dispatcher
        let readValue = self.readValue
        MainActor.assumeIsolated {
            dispatcher?.send(event, readValue(sender))
        }
    }
}

/// Render context: the slot table, the dispatcher, and the debug-stub flag.
@MainActor
public struct UIKitRenderContext {
    public var slots: UIKitSlotTable
    /// Where interactive controls send their events (forwarded to the guest
    /// `dispatch`). When nil, controls render but are inert.
    public var dispatcher: UIKitDispatcher?
    /// When true, an unregistered slot renders a visible labeled stub (instead of
    /// an empty `UIView`), which is what the tests assert against.
    public var showSlotStubs: Bool
    public init(slots: UIKitSlotTable = UIKitSlotTable(),
                dispatcher: UIKitDispatcher? = nil,
                showSlotStubs: Bool = true) {
        self.slots = slots
        self.dispatcher = dispatcher
        self.showSlotStubs = showSlotStubs
    }
}

// MARK: - Public render entry point

/// Reconstitute REAL UIKit from a `UIKitNode` tree. Returns the root `UIView`
/// with its subviews added and all resolved constraints activated.
@MainActor
public func renderUIKit(_ node: UIKitNode,
                        context: UIKitRenderContext = UIKitRenderContext()) -> UIView {
    UIKitRenderer(context: context).render(node)
}

/// The `identifier` this renderer stamps on every `NSLayoutConstraint` it
/// activates from the IR — so a caller (or a test) can distinguish Patch's
/// IR-derived constraints from UIKit's own internal ones (e.g. a `UIStackView`'s
/// axis engine).
public let patchUIKitConstraintIdentifier = "patch.uikit.ir"

// MARK: - Associated-object key for retaining trampolines

private nonisolated(unsafe) var trampolineKey: UInt8 = 0

// MARK: - Renderer

@MainActor
struct UIKitRenderer {
    let context: UIKitRenderContext

    /// Build the view tree, then resolve+activate constraints in a SECOND pass
    /// (so sibling references can be resolved by id across the whole subtree).
    func render(_ node: UIKitNode) -> UIView {
        var byID: [String: UIView] = [:]
        let root = buildView(node, into: &byID)
        var constraints: [NSLayoutConstraint] = []
        collectConstraints(node, view: root, byID: byID, into: &constraints)
        for c in constraints where c.identifier == nil {
            c.identifier = patchUIKitConstraintIdentifier
        }
        NSLayoutConstraint.activate(constraints)
        return root
    }

    // MARK: View construction (pass 1)

    /// Build the `UIView` for a node + recurse into children, registering each
    /// node's `id` → view so a sibling constraint can resolve it. Sets
    /// `translatesAutoresizingMaskIntoConstraints = false` on every view so the
    /// IR's constraints govern layout. The ROOT view keeps autoresizing ON
    /// (callers add it to a parent however they like) — actually we turn it off
    /// uniformly and let the caller flip the root if it wants a frame-based root;
    /// this keeps the common "embed in a constraint-driven parent" path correct.
    func buildView(_ node: UIKitNode, into byID: inout [String: UIView]) -> UIView {
        let view = makeView(node, into: &byID)
        view.translatesAutoresizingMaskIntoConstraints = false
        applyProps(node.props, to: view)
        if !node.props.id.isEmpty { byID[node.props.id] = view }
        return view
    }

    private func makeView(_ node: UIKitNode, into byID: inout [String: UIView]) -> UIView {
        switch node.kind {
        case .label(let text, let font, let textColor, let numberOfLines, let alignment):
            let label = UILabel()
            label.text = text
            if let font { label.font = resolveFont(font) }
            if let textColor { label.textColor = resolveColor(textColor) }
            if let numberOfLines { label.numberOfLines = numberOfLines }
            if let alignment { label.textAlignment = resolveTextAlignment(alignment) }
            return label

        case .button(let title, let titleColor, let font, let action):
            let button = UIButton(type: .system)
            button.setTitle(title, for: .normal)
            if let titleColor { button.setTitleColor(resolveColor(titleColor), for: .normal) }
            if let font { button.titleLabel?.font = resolveFont(font) }
            wire(button, event: action, controlEvents: .touchUpInside) { _ in .none }
            return button

        case .imageView(let image, let tintColor, let contentMode):
            let iv = UIImageView()
            iv.image = resolveImage(image)
            if let tintColor {
                iv.tintColor = resolveColor(tintColor)
                // A symbol/template image honors tintColor only in .alwaysTemplate.
                iv.image = iv.image?.withRenderingMode(.alwaysTemplate)
            }
            if let contentMode { iv.contentMode = resolveContentMode(contentMode) }
            return iv

        case .stackView(let axis, let spacing, let alignment, let distribution, let arranged):
            let stack = UIStackView()
            stack.axis = (axis == .vertical) ? .vertical : .horizontal
            if let spacing { stack.spacing = CGFloat(spacing) }
            if let alignment { stack.alignment = resolveStackAlignment(alignment) }
            if let distribution { stack.distribution = resolveStackDistribution(distribution) }
            for child in arranged {
                stack.addArrangedSubview(buildView(child, into: &byID))
            }
            return stack

        case .containerView(let children):
            let container = UIView()
            for child in children {
                container.addSubview(buildView(child, into: &byID))
            }
            return container

        case .switchControl(let isOn, let event):
            let sw = UISwitch()
            sw.isOn = isOn
            wire(sw, event: event, controlEvents: .valueChanged) { c in
                .bool((c as? UISwitch)?.isOn ?? false)
            }
            return sw

        case .uiSlider(let value, let mn, let mx, let event):
            let slider = UISlider()
            slider.minimumValue = Float(mn)
            slider.maximumValue = Float(mx)
            slider.value = Float(value)
            wire(slider, event: event, controlEvents: .valueChanged) { c in
                .double(Double((c as? UISlider)?.value ?? 0))
            }
            return slider

        case .uiTextField(let text, let placeholder, let event):
            let field = UITextField()
            field.text = text
            field.placeholder = placeholder
            wire(field, event: event, controlEvents: .editingChanged) { c in
                .string((c as? UITextField)?.text ?? "")
            }
            return field

        case .customSlot(let id, let label):
            if let native = context.slots.view(for: id) {
                native.translatesAutoresizingMaskIntoConstraints = false
                return native
            }
            // Unregistered slot: a visible labeled stub (or an empty UIView).
            if context.showSlotStubs {
                let stub = UILabel()
                stub.text = "[slot:\(id)\(label.isEmpty ? "" : " \(label)")]"
                stub.textColor = .secondaryLabel
                stub.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                stub.numberOfLines = 0
                return stub
            }
            return UIView()
        }
    }

    /// `addTarget` a trampoline to a control + retain it on the control (UIKit
    /// holds the target weakly).
    private func wire(_ control: UIControl, event: EventID,
                      controlEvents: UIControl.Event,
                      readValue: @escaping @MainActor @Sendable (UIControl) -> IRValue) {
        let trampoline = UIKitActionTrampoline(
            event: event, dispatcher: context.dispatcher, readValue: readValue)
        control.addTarget(trampoline, action: #selector(UIKitActionTrampoline.fire(_:)),
                          for: controlEvents)
        objc_setAssociatedObject(control, &trampolineKey, trampoline,
                                 .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    // MARK: View properties

    private func applyProps(_ p: UIKitViewProps, to view: UIView) {
        if let bg = p.backgroundColor { view.backgroundColor = resolveColor(bg) }
        if let r = p.cornerRadius { view.layer.cornerRadius = CGFloat(r) }
        if let clip = p.clipsToBounds { view.clipsToBounds = clip }
        if let a = p.alpha { view.alpha = CGFloat(a) }
        if let h = p.isHidden { view.isHidden = h }
        if let t = p.tintColor { view.tintColor = resolveColor(t) }
        // accessibilityIdentifier: explicit wins; else fall back to the node id so
        // a sibling-addressable view is still introspectable.
        if let aid = p.accessibilityIdentifier {
            view.accessibilityIdentifier = aid
        } else if !p.id.isEmpty {
            view.accessibilityIdentifier = p.id
        }
    }

    // MARK: Constraint resolution (pass 2)

    /// Walk the tree alongside the built views, resolving each node's
    /// `[IRConstraint]` to real `NSLayoutConstraint`s against the view graph.
    func collectConstraints(_ node: UIKitNode, view: UIView,
                            byID: [String: UIView],
                            into out: inout [NSLayoutConstraint]) {
        for c in node.constraints {
            if let resolved = resolveConstraint(c, on: view, byID: byID) {
                out.append(resolved)
            }
        }
        // Recurse: pair each child node with its already-built subview. Children
        // are the arranged subviews (stack) or the added subviews (container), in
        // declaration order — which matches build order.
        let childNodes = node.childNodes
        let childViews = childSubviews(of: view, kind: node.kind)
        guard childNodes.count == childViews.count else { return }
        for (cn, cv) in zip(childNodes, childViews) {
            collectConstraints(cn, view: cv, byID: byID, into: &out)
        }
    }

    /// The subviews that correspond to a node's `childNodes`, in order.
    private func childSubviews(of view: UIView, kind: UIKitNodeKind) -> [UIView] {
        switch kind {
        case .stackView:
            return (view as? UIStackView)?.arrangedSubviews ?? []
        case .containerView:
            return view.subviews
        default:
            return []
        }
    }

    /// Resolve one `IRConstraint` to a real `NSLayoutConstraint` using the
    /// low-level `NSLayoutConstraint(item:attribute:…)` form (which expresses the
    /// full multiplier/constant/relation grammar uniformly — anchors are sugar
    /// over this). Returns nil if a sibling reference can't be resolved (the
    /// constraint is dropped rather than crashing).
    private func resolveConstraint(_ c: IRConstraint, on view: UIView,
                                   byID: [String: UIView]) -> NSLayoutConstraint? {
        let firstAttr = layoutAttribute(c.first)
        let relation = layoutRelation(c.relation)

        guard let second = c.second else {
            // Constant width/height: second item is nil, attribute .notAnAttribute.
            return NSLayoutConstraint(
                item: view, attribute: firstAttr, relatedBy: relation,
                toItem: nil, attribute: .notAnAttribute,
                multiplier: CGFloat(c.multiplier == 0 ? 1 : c.multiplier),
                constant: CGFloat(c.constant)).withPriority(c.priority)
        }

        guard let secondItem = resolveTarget(second.target, ownerView: view, byID: byID) else {
            return nil   // unresolvable sibling — drop, don't crash
        }
        return NSLayoutConstraint(
            item: view, attribute: firstAttr, relatedBy: relation,
            toItem: secondItem, attribute: layoutAttribute(second.anchor),
            multiplier: CGFloat(c.multiplier == 0 ? 1 : c.multiplier),
            constant: CGFloat(c.constant)).withPriority(c.priority)
    }

    /// Resolve an `IRAnchorTarget` to the real layout item (a `UIView` or a
    /// `UILayoutGuide` for the safe area).
    private func resolveTarget(_ target: IRAnchorTarget, ownerView: UIView,
                               byID: [String: UIView]) -> AnyObject? {
        switch target {
        case .superview:
            return ownerView.superview
        case .safeArea:
            return ownerView.superview?.safeAreaLayoutGuide
        case .selfView:
            return ownerView
        case .sibling(let id):
            return byID[id]
        }
    }

    // MARK: Value-type resolution (REUSES the shared IR types)

    private func resolveColor(_ c: ColorRef) -> UIColor {
        switch c {
        case .rgba(let col):
            return UIColor(red: CGFloat(col.r), green: CGFloat(col.g),
                           blue: CGFloat(col.b), alpha: CGFloat(col.a))
        case .named(let name):
            return UIKitRenderer.namedColor(name)
        case .hostToken:
            // A design-system color TOKEN (SwiftUI lowering feature). The UIKit path
            // has no token table wired yet, so fall back to the adaptive default —
            // visible and safe. (The shared IR carries the case; UIKit token resolution
            // can be added without changing this enum.)
            return .label
        }
    }

    /// Map a SwiftUI/system color name to a real (adaptive) `UIColor`. Unknown
    /// names fall back to `.label` (a visible, adaptive default).
    static func namedColor(_ name: String) -> UIColor {
        switch name {
        case "black": return .black
        case "white": return .white
        case "clear": return .clear
        case "red": return .systemRed
        case "orange": return .systemOrange
        case "yellow": return .systemYellow
        case "green": return .systemGreen
        case "mint": if #available(iOS 15.0, tvOS 15.0, *) { return .systemMint } else { return .systemGreen }
        case "teal": return .systemTeal
        case "cyan": if #available(iOS 15.0, tvOS 15.0, *) { return .systemCyan } else { return .systemTeal }
        case "blue": return .systemBlue
        case "indigo": return .systemIndigo
        case "purple": return .systemPurple
        case "pink": return .systemPink
        case "brown": return .systemBrown
        case "gray", "grey": return .systemGray
        case "primary", "label": return .label
        case "secondary", "secondaryLabel": return .secondaryLabel
        case "systemBackground", "background": return .systemBackground
        case "secondarySystemBackground": return .secondarySystemBackground
        case "separator": return .separator
        case "tint", "accentColor": return .tintColor
        default: return .label
        }
    }

    private func resolveFont(_ f: IRFont) -> UIFont {
        // A named text style takes precedence (adaptive Dynamic Type), mirroring
        // the SwiftUI renderer. Then apply weight via the font descriptor; a
        // design (rounded/serif/monospaced) applies a design trait when available.
        var base: UIFont
        if let style = f.style {
            base = UIFont.preferredFont(forTextStyle: textStyle(style))
        } else {
            base = UIFont.systemFont(ofSize: CGFloat(f.size ?? 17),
                                     weight: f.weight.map(fontWeight) ?? .regular)
        }
        if f.style != nil, let w = f.weight {
            let d = base.fontDescriptor.addingAttributes(
                [.traits: [UIFontDescriptor.TraitKey.weight: fontWeight(w)]])
            base = UIFont(descriptor: d, size: base.pointSize)
        }
        if let design = f.design, design != .default {
            let systemDesign: UIFontDescriptor.SystemDesign
            switch design {
            case .serif: systemDesign = .serif
            case .rounded: systemDesign = .rounded
            case .monospaced: systemDesign = .monospaced
            case .default: systemDesign = .default
            }
            if let d = base.fontDescriptor.withDesign(systemDesign) {
                base = UIFont(descriptor: d, size: base.pointSize)
            }
        }
        return base
    }

    private func fontWeight(_ w: IRFont.Weight) -> UIFont.Weight {
        switch w {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        }
    }

    private func textStyle(_ s: IRFont.TextStyle) -> UIFont.TextStyle {
        switch s {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .body: return .body
        case .callout: return .callout
        case .footnote: return .footnote
        case .caption: return .caption1
        case .caption2: return .caption2
        }
    }

    private func resolveTextAlignment(_ a: IRUITextAlignment) -> NSTextAlignment {
        switch a {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        case .justified: return .justified
        case .natural: return .natural
        }
    }

    private func resolveImage(_ r: IRImageRef) -> UIImage? {
        switch r {
        case .systemName(let name): return UIImage(systemName: name)
        case .assetName(let name): return UIImage(named: name)
        }
    }

    private func resolveContentMode(_ m: IRUIContentMode) -> UIView.ContentMode {
        switch m {
        case .scaleToFill: return .scaleToFill
        case .scaleAspectFit: return .scaleAspectFit
        case .scaleAspectFill: return .scaleAspectFill
        case .center: return .center
        case .top: return .top
        case .bottom: return .bottom
        case .left: return .left
        case .right: return .right
        case .topLeft: return .topLeft
        case .topRight: return .topRight
        case .bottomLeft: return .bottomLeft
        case .bottomRight: return .bottomRight
        case .redraw: return .redraw
        }
    }

    private func resolveStackAlignment(_ a: IRStackAlignment) -> UIStackView.Alignment {
        switch a {
        case .fill: return .fill
        case .leading: return .leading
        case .firstBaseline: return .firstBaseline
        case .center: return .center
        case .trailing: return .trailing
        case .lastBaseline: return .lastBaseline
        }
    }

    private func resolveStackDistribution(_ d: IRStackDistribution) -> UIStackView.Distribution {
        switch d {
        case .fill: return .fill
        case .fillEqually: return .fillEqually
        case .fillProportionally: return .fillProportionally
        case .equalSpacing: return .equalSpacing
        case .equalCentering: return .equalCentering
        }
    }

    private func layoutAttribute(_ a: IRAnchor) -> NSLayoutConstraint.Attribute {
        switch a {
        case .leading: return .leading
        case .trailing: return .trailing
        case .top: return .top
        case .bottom: return .bottom
        case .left: return .left
        case .right: return .right
        case .width: return .width
        case .height: return .height
        case .centerX: return .centerX
        case .centerY: return .centerY
        case .firstBaseline: return .firstBaseline
        case .lastBaseline: return .lastBaseline
        }
    }

    private func layoutRelation(_ r: IRConstraintRelation) -> NSLayoutConstraint.Relation {
        switch r {
        case .eq: return .equal
        case .ge: return .greaterThanOrEqual
        case .le: return .lessThanOrEqual
        }
    }
}

private extension NSLayoutConstraint {
    /// Apply an optional priority (nil = leave `.required`).
    func withPriority(_ p: Double?) -> NSLayoutConstraint {
        if let p { self.priority = UILayoutPriority(Float(p)) }
        return self
    }
}

#else

// On a platform WITHOUT UIKit (macOS / Linux) the renderer is absent. This empty
// enum keeps the module non-empty so `swift build` succeeds everywhere; the
// renderer + its tests run on the iOS/tvOS/visionOS family (and the on-device E2E).
public enum PatchRenderUIKitUnavailable {}

#endif
