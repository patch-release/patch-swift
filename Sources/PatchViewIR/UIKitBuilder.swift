// UIKitBuilder.swift — an ergonomic node-builder so a *lowered* UIKit body reads
// close to the imperative UIKit it came from. This is what the engine's lowering
// emits into the guest, and what a human can hand-write to model a construction.
//
// e.g. the UIKit:
//     let label = UILabel(); label.text = "Hi"; label.font = .boldSystemFont(ofSize: 17)
//     let stack = UIStackView(arrangedSubviews: [label]); stack.axis = .vertical
// models as:
//     UI.stack(axis: .vertical, arranged: [ UI.label("Hi", font: .init(size: 17, weight: .bold)) ])
//
// Pure value types; compiles into the wasm guest unchanged (no imports). Mirrors
// `N` (the SwiftUI builder) — same module, reuses the shared value types.

public enum UI {

    // MARK: - Leaf views

    /// `UILabel`.
    public static func label(_ text: String,
                             font: IRFont? = nil,
                             textColor: ColorRef? = nil,
                             numberOfLines: Int? = nil,
                             alignment: IRUITextAlignment? = nil) -> UIKitNode {
        UIKitNode(.label(text: text, font: font, textColor: textColor,
                         numberOfLines: numberOfLines, alignment: alignment))
    }

    /// `UIButton` (system) with a `.normal`-state title + an action event.
    public static func button(_ title: String,
                              titleColor: ColorRef? = nil,
                              font: IRFont? = nil,
                              action: String) -> UIKitNode {
        UIKitNode(.button(title: title, titleColor: titleColor, font: font,
                          action: EventID(action)))
    }

    /// `UIImageView` with an SF Symbol image.
    public static func image(systemName: String,
                             tintColor: ColorRef? = nil,
                             contentMode: IRUIContentMode? = nil) -> UIKitNode {
        UIKitNode(.imageView(image: .systemName(systemName),
                             tintColor: tintColor, contentMode: contentMode))
    }

    /// `UIImageView` with an Asset-Catalog image.
    public static func image(named: String,
                             tintColor: ColorRef? = nil,
                             contentMode: IRUIContentMode? = nil) -> UIKitNode {
        UIKitNode(.imageView(image: .assetName(named),
                             tintColor: tintColor, contentMode: contentMode))
    }

    // MARK: - Containers

    /// `UIStackView`.
    public static func stack(axis: IRStackAxis,
                             spacing: Double? = nil,
                             alignment: IRStackAlignment? = nil,
                             distribution: IRStackDistribution? = nil,
                             arranged: [UIKitNode]) -> UIKitNode {
        UIKitNode(.stackView(axis: axis, spacing: spacing, alignment: alignment,
                             distribution: distribution, arranged: arranged))
    }

    /// A plain `UIView` container (children added via `addSubview`).
    public static func container(_ children: [UIKitNode]) -> UIKitNode {
        UIKitNode(.containerView(children: children))
    }

    // MARK: - Cheap stateful controls

    /// `UISwitch`.
    public static func switchControl(isOn: Bool, event: String) -> UIKitNode {
        UIKitNode(.switchControl(isOn: isOn, event: EventID(event)))
    }

    /// `UISlider`.
    public static func slider(value: Double, min: Double = 0, max: Double = 1,
                              event: String) -> UIKitNode {
        UIKitNode(.uiSlider(value: value, min: min, max: max, event: EventID(event)))
    }

    /// `UITextField`.
    public static func textField(text: String, placeholder: String = "",
                                 event: String) -> UIKitNode {
        UIKitNode(.uiTextField(text: text, placeholder: placeholder, event: EventID(event)))
    }

    /// A native leaf slot the host fills (the escape-hatch).
    public static func slot(id: String, label: String = "") -> UIKitNode {
        UIKitNode(.customSlot(id: id, label: label))
    }
}

// MARK: - Chainable view-property + constraint helpers

extension UIKitNode {
    /// Set the node's stable `id` (for sibling-constraint targeting).
    public func id(_ s: String) -> UIKitNode {
        var p = props; p.id = s; return withProps(p)
    }
    public func background(_ c: ColorRef) -> UIKitNode {
        var p = props; p.backgroundColor = c; return withProps(p)
    }
    public func cornerRadius(_ r: Double) -> UIKitNode {
        var p = props; p.cornerRadius = r; return withProps(p)
    }
    public func clipsToBounds(_ b: Bool) -> UIKitNode {
        var p = props; p.clipsToBounds = b; return withProps(p)
    }
    public func alpha(_ a: Double) -> UIKitNode {
        var p = props; p.alpha = a; return withProps(p)
    }
    public func hidden(_ b: Bool) -> UIKitNode {
        var p = props; p.isHidden = b; return withProps(p)
    }
    public func tint(_ c: ColorRef) -> UIKitNode {
        var p = props; p.tintColor = c; return withProps(p)
    }
    public func accessibilityIdentifier(_ s: String) -> UIKitNode {
        var p = props; p.accessibilityIdentifier = s; return withProps(p)
    }

    // Constraint sugar (the common forms).

    /// Pin one anchor to another view's anchor (default the superview's).
    public func pin(_ first: IRAnchor, to anchor: IRAnchor,
                    of target: IRAnchorTarget = .superview,
                    relation: IRConstraintRelation = .eq,
                    multiplier: Double = 1, constant: Double = 0,
                    priority: Double? = nil) -> UIKitNode {
        constrained(IRConstraint(first: first, relation: relation,
                                 second: IRAnchorRef(target: target, anchor: anchor),
                                 multiplier: multiplier, constant: constant, priority: priority))
    }

    /// A constant size constraint (`widthAnchor.constraint(equalToConstant:)`).
    public func size(_ dimension: IRAnchor, _ constant: Double,
                     relation: IRConstraintRelation = .eq,
                     priority: Double? = nil) -> UIKitNode {
        constrained(IRConstraint(first: dimension, relation: relation, second: nil,
                                 constant: constant, priority: priority))
    }
}
