// Builder.swift — an ergonomic node-builder so a *lowered* body reads almost
// exactly like the SwiftUI it came from. This is what the engine's lowering
// emits into the guest, and what a human can hand-write to model a body.
//
// e.g. the SwiftUI:
//     VStack(spacing: 8) { Text("Hi").font(.title).bold() }
// lowers to:
//     N.vstack(spacing: 8) { [ N.text("Hi").font(.title).bold() ] }
//
// Pure value types; compiles into the wasm guest unchanged.

public enum N {
    // Primitives
    public static func text(_ s: String) -> ViewNode { ViewNode(.text(s)) }
    public static func image(systemName: String) -> ViewNode { ViewNode(.image(systemName: systemName)) }
    public static func spacer(minLength: Double? = nil) -> ViewNode { ViewNode(.spacer(minLength: minLength)) }
    public static var divider: ViewNode { ViewNode(.divider) }
    public static func color(_ c: ColorRef) -> ViewNode { ViewNode(.color(c)) }
    public static func color(named: String) -> ViewNode { ViewNode(.color(.named(named))) }
    public static func shape(_ k: ShapeKind) -> ViewNode { ViewNode(.shape(k)) }

    // Containers
    public static func vstack(alignment: IRHorizontalAlignment? = nil,
                              spacing: Double? = nil,
                              _ children: [ViewNode]) -> ViewNode {
        ViewNode(.vstack(alignment: alignment, spacing: spacing, children: children))
    }
    public static func hstack(alignment: IRVerticalAlignment? = nil,
                              spacing: Double? = nil,
                              _ children: [ViewNode]) -> ViewNode {
        ViewNode(.hstack(alignment: alignment, spacing: spacing, children: children))
    }
    public static func zstack(alignment: IRAlignment? = nil,
                              _ children: [ViewNode]) -> ViewNode {
        ViewNode(.zstack(alignment: alignment, children: children))
    }
    public static func group(_ children: [ViewNode]) -> ViewNode {
        ViewNode(.group(children: children))
    }
    public static func forEach(_ children: [ViewNode]) -> ViewNode {
        ViewNode(.forEach(children: children))
    }

    // Interaction
    public static func button(actionID: String, label: [ViewNode]) -> ViewNode {
        ViewNode(.button(actionID: actionID, label: label))
    }
    public static func button(_ title: String, actionID: String) -> ViewNode {
        ViewNode(.button(actionID: actionID, label: [N.text(title)]))
    }

    // Stateful controls (interactive). The `value` is read
    // from guest state at emit time; `event` is what the host dispatches back
    // into the guest's `dispatch` when the control's binding changes.
    public static func toggle(_ title: String, isOn: Bool, event: String) -> ViewNode {
        ViewNode(.toggle(label: [N.text(title)], value: isOn, event: EventID(event)))
    }
    public static func toggle(isOn: Bool, event: String, label: [ViewNode]) -> ViewNode {
        ViewNode(.toggle(label: label, value: isOn, event: EventID(event)))
    }
    public static func slider(value: Double, in range: ClosedRange<Double>,
                              step: Double? = nil, event: String) -> ViewNode {
        ViewNode(.slider(value: value, min: range.lowerBound, max: range.upperBound,
                         step: step, event: EventID(event)))
    }
    public static func stepper(_ title: String, value: Int, in range: ClosedRange<Int>? = nil,
                               step: Int = 1, event: String) -> ViewNode {
        ViewNode(.stepper(label: [N.text(title)], value: value,
                          min: range?.lowerBound, max: range?.upperBound,
                          step: step, event: EventID(event)))
    }
    public static func textField(_ placeholder: String, text: String, event: String) -> ViewNode {
        ViewNode(.textField(placeholder: placeholder, value: text, event: EventID(event)))
    }

    // Native fallback
    public static func opaque(id: String, label: String) -> ViewNode {
        ViewNode(.opaque(id: id, label: label))
    }
}

// MARK: - Chainable modifier sugar (mirrors SwiftUI's `.font(...)` etc.)

extension ViewNode {
    public func font(_ f: IRFont) -> ViewNode { with(.font(f)) }
    public func font(style: IRFont.TextStyle) -> ViewNode { with(.font(IRFont(style: style))) }
    public func fontSize(_ size: Double, weight: IRFont.Weight? = nil,
                         design: IRFont.Design? = nil) -> ViewNode {
        with(.font(IRFont(size: size, weight: weight, design: design)))
    }
    public func foregroundColor(_ c: ColorRef) -> ViewNode { with(.foregroundColor(c)) }
    public func foregroundColor(named: String) -> ViewNode { with(.foregroundColor(.named(named))) }
    public func bold() -> ViewNode { with(.bold) }
    public func italic() -> ViewNode { with(.italic) }
    public func padding(_ insets: IREdgeInsets) -> ViewNode { with(.padding(insets)) }
    public func padding(_ value: Double = 16) -> ViewNode { with(.padding(.all(value))) }
    public func frame(width: Double? = nil, height: Double? = nil,
                      alignment: IRAlignment? = nil) -> ViewNode {
        with(.frame(width: width, height: height, alignment: alignment))
    }
    public func background(_ c: ColorRef) -> ViewNode { with(.background(c)) }
    public func background(named: String) -> ViewNode { with(.background(.named(named))) }
    public func cornerRadius(_ r: Double) -> ViewNode { with(.cornerRadius(r)) }
    public func opacity(_ o: Double) -> ViewNode { with(.opacity(o)) }
    public func lineLimit(_ n: Int?) -> ViewNode { with(.lineLimit(n)) }
    public func multilineTextAlignment(_ a: IRTextAlignment) -> ViewNode {
        with(.multilineTextAlignment(a))
    }
    /// `.onTapGesture { ... }` lowered as a discrete event.
    public func onTapGesture(event: String) -> ViewNode { with(.onTapGesture(EventID(event))) }
}
