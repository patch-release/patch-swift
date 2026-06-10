// Render.swift — the native SDK renderer: ViewNode IR -> REAL SwiftUI.
// =====================================================================
// This is the host half of Breakthrough #3. The WASM guest builds a `ViewNode`
// tree and serializes it across the boundary; this renderer reconstitutes a
// *real* SwiftUI `AnyView` from that tree — real `Text` with real `Font`,
// real `VStack`/`HStack`/`ZStack`, real `.padding`/`.background`/`.frame`/etc.
//
// Re-rendering on state change is "free": when the guest re-emits a new tree
// (because @State changed and the host re-invoked `view_body`), the host just
// calls `render` on the new tree. A SwiftUI `View` wrapper (`FrontierView`,
// below) wires that into the SwiftUI update loop.
//
// Button callbacks: the IR carries an `actionID` string. The host owns a side
// table (`ActionTable`) mapping ids -> real closures. The renderer looks the
// closure up and installs it as the Button's action. This is how a WASM-lowered
// `Button(action:)` re-acquires its native behavior.

#if canImport(SwiftUI)
import SwiftUI
import PatchViewIR

// MARK: - Host wiring tables

/// Maps a lowered `Button`'s `actionID` to the real native closure the host
/// supplies (the engine replaces the in-body closure with a callback id; the
/// host re-attaches behavior here).
public final class ActionTable {
    private var actions: [String: () -> Void] = [:]
    public init() {}
    public func set(_ id: String, _ action: @escaping () -> Void) { actions[id] = action }
    public func action(for id: String) -> (() -> Void)? { actions[id] }
}

/// Maps an `.opaque` node's id to a real native SwiftUI view the host supplies
/// for the bits that don't lower (custom representables, gesture-driven views,
/// etc.). If no view is registered, a labeled placeholder renders so the gap is
/// visible rather than silent.
public final class OpaqueTable {
    private var views: [String: AnyView] = [:]
    public init() {}
    public func set(_ id: String, _ view: AnyView) { views[id] = view }
    public func view(for id: String) -> AnyView? { views[id] }
}

/// The sink an interactive control's binding fires when the user changes it:
/// it carries the `EventID` (which UPDATE branch in the guest runs) and the new
/// `IRValue`. The host forwards this to the guest's `dispatch` export, the guest
/// mutates its state in WASM and re-emits, and the host re-renders. This is the
/// host end of the TEA loop.
@MainActor
public final class Dispatcher {
    public typealias Sink = @MainActor (EventID, IRValue) -> Void
    private let sink: Sink
    public init(_ sink: @escaping Sink) { self.sink = sink }
    public func send(_ event: EventID, _ value: IRValue) { sink(event, value) }
}

public struct RenderContext {
    public var actions: ActionTable
    public var opaques: OpaqueTable
    /// Where interactive controls send their events (the host forwards to the
    /// guest `dispatch`). When nil, controls render but are inert (read-only).
    public var dispatcher: Dispatcher?
    /// When true, an unregistered opaque slot renders a visible debug stub
    /// (instead of `EmptyView`), which is what the tests assert against.
    public var showOpaqueStubs: Bool
    public init(actions: ActionTable = ActionTable(),
                opaques: OpaqueTable = OpaqueTable(),
                dispatcher: Dispatcher? = nil,
                showOpaqueStubs: Bool = true) {
        self.actions = actions
        self.opaques = opaques
        self.dispatcher = dispatcher
        self.showOpaqueStubs = showOpaqueStubs
    }
}

// MARK: - Public render entry point

/// Reconstitute REAL SwiftUI from a `ViewNode` tree.
@MainActor
public func render(_ node: ViewNode, context: RenderContext = RenderContext()) -> AnyView {
    Renderer(context: context).render(node)
}

// MARK: - Renderer

@MainActor
struct Renderer {
    let context: RenderContext

    func render(_ node: ViewNode) -> AnyView {
        let base = renderKind(node.kind)
        return applyModifiers(node.modifiers, to: base)
    }

    private func renderChildren(_ nodes: [ViewNode]) -> AnyView {
        // ForEach over indices keeps a stable identity for the unrolled list.
        AnyView(
            ForEach(Array(nodes.enumerated()), id: \.offset) { _, child in
                self.render(child)
            }
        )
    }

    private func renderKind(_ kind: NodeKind) -> AnyView {
        switch kind {
        case .text(let s):
            return AnyView(Text(s))

        case .image(let systemName):
            return AnyView(Image(systemName: systemName))

        case .spacer(let minLength):
            if let m = minLength { return AnyView(Spacer(minLength: m)) }
            return AnyView(Spacer())

        case .divider:
            return AnyView(Divider())

        case .color(let c):
            return AnyView(color(c))

        case .shape(let s):
            return AnyView(shape(s))

        case .vstack(let alignment, let spacing, let children):
            return AnyView(
                VStack(alignment: horizontal(alignment), spacing: spacing.map { CGFloat($0) }) {
                    renderChildren(children)
                }
            )

        case .hstack(let alignment, let spacing, let children):
            return AnyView(
                HStack(alignment: vertical(alignment), spacing: spacing.map { CGFloat($0) }) {
                    renderChildren(children)
                }
            )

        case .zstack(let alignment, let children):
            return AnyView(
                ZStack(alignment: zalignment(alignment)) {
                    renderChildren(children)
                }
            )

        case .group(let children):
            return AnyView(Group { renderChildren(children) })

        case .forEach(let children):
            return renderChildren(children)

        case .button(let actionID, let label):
            let action = context.actions.action(for: actionID) ?? {}
            return AnyView(
                Button(action: action) { renderChildren(label) }
            )

        // MARK: Stateful controls — real SwiftUI bound to the guest dispatch.

        case .toggle(let label, let value, let event):
            // The Binding's GET returns the WASM-emitted value (state lives in
            // the guest). The SET forwards the new value as an event into the
            // guest's dispatch — the guest mutates state + re-emits, and the
            // host re-renders with the new value. SwiftUI never owns this state.
            let binding = Binding<Bool>(
                get: { value },
                set: { [d = context.dispatcher] new in d?.send(event, .bool(new)) }
            )
            return AnyView(Toggle(isOn: binding) { renderChildren(label) })

        case .slider(let value, let mn, let mx, let step, let event):
            // `Slider` is unavailable on tvOS/watchOS — degrade to a read-only
            // label there (the value still came from WASM) rather than fail to
            // compile. iOS/macOS/visionOS get the real bound control.
            #if os(tvOS) || os(watchOS)
            return AnyView(Text("slider:\(value)").font(.caption2).foregroundColor(.secondary))
            #else
            let binding = Binding<Double>(
                get: { value },
                set: { [d = context.dispatcher] new in d?.send(event, .double(new)) }
            )
            if let step {
                return AnyView(Slider(value: binding, in: mn...mx, step: step))
            }
            return AnyView(Slider(value: binding, in: mn...mx))
            #endif

        case .stepper(let label, let value, let mn, let mx, let step, let event):
            // `Stepper` is unavailable on tvOS/watchOS — degrade to its label +
            // value there. iOS/macOS/visionOS get the real bound control.
            #if os(tvOS) || os(watchOS)
            _ = (mn, mx, step, event)
            return AnyView(renderChildren(label))
            #else
            // Stepper drives an Int. Clamp to the (optional) range in the host
            // setter so the dispatched value is always valid; the guest still
            // owns the authoritative state.
            let binding = Binding<Int>(
                get: { value },
                set: { [d = context.dispatcher] new in
                    var v = new
                    if let mn { v = max(mn, v) }
                    if let mx { v = min(mx, v) }
                    d?.send(event, .int(v))
                }
            )
            return AnyView(Stepper(value: binding, step: step) { renderChildren(label) })
            #endif

        case .textField(let placeholder, let value, let event):
            let binding = Binding<String>(
                get: { value },
                set: { [d = context.dispatcher] new in d?.send(event, .string(new)) }
            )
            return AnyView(TextField(placeholder, text: binding))

        case .opaque(let id, let label):
            if let v = context.opaques.view(for: id) { return v }
            if context.showOpaqueStubs {
                return AnyView(
                    Text("native:\(label)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                )
            }
            return AnyView(EmptyView())
        }
    }

    // MARK: Modifier replay

    private func applyModifiers(_ mods: [Modifier], to view: AnyView) -> AnyView {
        var v = view
        for m in mods { v = apply(m, to: v) }
        return v
    }

    private func apply(_ m: Modifier, to v: AnyView) -> AnyView {
        switch m {
        case .font(let f):
            return AnyView(v.font(font(f)))
        case .foregroundColor(let c):
            return AnyView(v.foregroundColor(color(c)))
        case .bold:
            return AnyView(v.bold())
        case .italic:
            return AnyView(v.italic())
        case .padding(let insets):
            return AnyView(v.padding(edgeInsets(insets)))
        case .frame(let w, let h, let a):
            return AnyView(v.frame(width: w.map { CGFloat($0) },
                                   height: h.map { CGFloat($0) },
                                   alignment: zalignment(a)))
        case .background(let c):
            return AnyView(v.background(color(c)))
        case .cornerRadius(let r):
            return AnyView(v.cornerRadius(CGFloat(r)))
        case .opacity(let o):
            return AnyView(v.opacity(o))
        case .lineLimit(let n):
            return AnyView(v.lineLimit(n))
        case .multilineTextAlignment(let a):
            return AnyView(v.multilineTextAlignment(textAlignment(a)))
        case .onTapGesture(let event):
            // A discrete tap → a guest event. The closure dispatches into WASM.
            return AnyView(v.onTapGesture { [d = context.dispatcher] in
                d?.send(event, .none)
            })
        case .opaque:
            // A modifier we couldn't lower — leave the view unchanged. The
            // native-fallback owns whatever behavior it implied.
            return v
        }
    }

    // MARK: Mapping IR -> SwiftUI value types

    func color(_ ref: ColorRef) -> Color {
        switch ref {
        case .named(let name): return Renderer.systemColor(name)
        case .rgba(let c): return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
        }
    }

    static func systemColor(_ name: String) -> Color {
        switch name {
        case "primary": return .primary
        case "secondary": return .secondary
        case "accent", "accentColor": return .accentColor
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "mint": return .mint
        case "teal": return .teal
        case "cyan": return .cyan
        case "blue": return .blue
        case "indigo": return .indigo
        case "purple": return .purple
        case "pink": return .pink
        case "brown": return .brown
        case "white": return .white
        case "gray", "grey": return .gray
        case "black": return .black
        case "clear": return .clear
        default: return .primary
        }
    }

    func font(_ f: IRFont) -> Font {
        var base: Font
        if let style = f.style {
            base = Font.system(textStyle(style))
        } else if let size = f.size {
            base = Font.system(size: CGFloat(size),
                               weight: weight(f.weight),
                               design: design(f.design))
            return base   // size path already carries weight+design
        } else {
            base = Font.body
        }
        if let w = f.weight { base = base.weight(weight(w)) }
        return base
    }

    private func textStyle(_ s: IRFont.TextStyle) -> Font.TextStyle {
        switch s {
        case .largeTitle: return .largeTitle
        case .title: return .title
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .body: return .body
        case .callout: return .callout
        case .footnote: return .footnote
        case .caption: return .caption
        case .caption2: return .caption2
        }
    }

    private func weight(_ w: IRFont.Weight?) -> Font.Weight {
        switch w {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .regular, .none: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        }
    }

    private func design(_ d: IRFont.Design?) -> Font.Design {
        switch d {
        case .serif: return .serif
        case .rounded: return .rounded
        case .monospaced: return .monospaced
        case .default, .none: return .default
        }
    }

    func shape(_ k: ShapeKind) -> some View {
        Group {
            switch k {
            case .rectangle: Rectangle()
            case .roundedRectangle(let r): RoundedRectangle(cornerRadius: CGFloat(r))
            case .circle: Circle()
            case .ellipse: Ellipse()
            case .capsule: Capsule()
            }
        }
    }

    func edgeInsets(_ i: IREdgeInsets) -> EdgeInsets {
        EdgeInsets(top: CGFloat(i.top), leading: CGFloat(i.leading),
                   bottom: CGFloat(i.bottom), trailing: CGFloat(i.trailing))
    }

    func horizontal(_ a: IRHorizontalAlignment?) -> HorizontalAlignment {
        switch a {
        case .leading: return .leading
        case .trailing: return .trailing
        case .center, .none: return .center
        }
    }
    func vertical(_ a: IRVerticalAlignment?) -> VerticalAlignment {
        switch a {
        case .top: return .top
        case .bottom: return .bottom
        case .firstTextBaseline: return .firstTextBaseline
        case .lastTextBaseline: return .lastTextBaseline
        case .center, .none: return .center
        }
    }
    func zalignment(_ a: IRAlignment?) -> Alignment {
        switch a {
        case .leading: return .leading
        case .trailing: return .trailing
        case .top: return .top
        case .bottom: return .bottom
        case .topLeading: return .topLeading
        case .topTrailing: return .topTrailing
        case .bottomLeading: return .bottomLeading
        case .bottomTrailing: return .bottomTrailing
        case .center, .none: return .center
        }
    }
    func textAlignment(_ a: IRTextAlignment) -> TextAlignment {
        switch a {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}
#endif
