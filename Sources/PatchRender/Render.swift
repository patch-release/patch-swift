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
import Foundation
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

/// A DESIGN-SYSTEM TOKEN value the host app supplies for a `.hostToken(id)` color
/// or `.fontToken(id)` font in the lowered tree. The build-time thunk evaluates the
/// real token expression (`Theme.Colors.ink`, `Theme.Font.body(13, weight: .semibold)`)
/// NATIVELY → one of these, keyed by the content-stable id. So a token-using modifier
/// rides WASM (patchable) while its concrete VALUE comes from the compiled-in app.
/// A `Color` is resolved data; a `Font` is opaque (no introspectable descriptor), so
/// it's carried as the live `Font` the renderer applies directly.
///
/// A `number` is a design-system `CGFloat`/`Double` constant (`Theme.Radius.lg`) used
/// in a NUMERIC position (`.cornerRadius(…)`, `.padding(…)`, `frame`). Unlike a
/// color/font (applied by the renderer over the tree), a numeric token is consumed
/// INSIDE the guest body, so `PatchedBodyHost` merges it into the guest's input JSON
/// under a reserved `__numtok_<id>` key (like a `__geo_*` input) rather than handing it
/// to the renderer — the body then reads the real token value in WASM.
public enum PatchHostToken: Sendable {
    case color(Color)
    case font(Font)
    case number(Double)
    /// A host-resolved STRING used as `Text(…)` content whose expression isn't
    /// guest-reconstructable (an enum's computed-String member like `confidence.label`).
    /// Like a `number`, it's consumed INSIDE the guest body, so `PatchedBodyHost` merges
    /// it into the guest's input JSON under a reserved `__strtok_<id>` key (not handed to
    /// the renderer) — the body reads the real String in WASM as the text content.
    case string(String)
}

/// Maps a token id to its host-supplied `Color`/`Font`. Filled by `PatchedBodyHost`
/// from the thunk's `__patchTokens()` before rendering, then read by the renderer
/// when it hits a `.hostToken(id)` color or a `.fontToken(id)` modifier. A missing
/// id is demote-handled upstream (PatchedBodyHost refuses to render a tree whose
/// token id the thunk didn't cover), so the renderer's fallbacks here are belt-and-
/// suspenders (`.primary` / no font change) rather than the primary safety net.
public final class HostTokenTable {
    private var tokens: [String: PatchHostToken] = [:]
    public init() {}
    public func set(_ id: String, _ token: PatchHostToken) { tokens[id] = token }
    public func color(for id: String) -> Color? {
        if case .color(let c)? = tokens[id] { return c }
        return nil
    }
    public func font(for id: String) -> Font? {
        if case .font(let f)? = tokens[id] { return f }
        return nil
    }
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

/// Re-evaluate a `geometryReader` node's lowered child body against a LIVE
/// `GeometryProxy`. Given the reader's content-stable `id` and the proxy's
/// `size`/`frame(in:.local)` scalars, the host re-invokes the guest's `view_body`
/// with those values merged as reserved `__geo_*` inputs and returns the children
/// of the SAME `geometryReader` node in the re-emitted tree (matched by `id`).
/// Returns nil when the rebuild can't run (no live module / decode failure) — the
/// renderer then falls back to the statically-lowered children. `PatchedBodyHost`
/// supplies this; a bare `render(_:)` leaves it nil.
@MainActor
public struct GeometryRebuild {
    public typealias Resolve = @MainActor (_ id: String, _ width: Double, _ height: Double,
                                           _ minX: Double, _ minY: Double) -> [ViewNode]?
    let resolve: Resolve
    public init(_ resolve: @escaping Resolve) { self.resolve = resolve }
    func callAsFunction(_ id: String, _ w: Double, _ h: Double, _ x: Double, _ y: Double) -> [ViewNode]? {
        resolve(id, w, h, x, y)
    }
}

public struct RenderContext {
    public var actions: ActionTable
    public var opaques: OpaqueTable
    /// Host-supplied DESIGN-SYSTEM TOKEN values (`.hostToken(id)` colors,
    /// `.fontToken(id)` fonts) the thunk resolved from the app's compiled-in tokens.
    public var tokens: HostTokenTable
    /// Where interactive controls send their events (the host forwards to the
    /// guest `dispatch`). When nil, controls render but are inert (read-only).
    public var dispatcher: Dispatcher?
    /// When true, an unregistered opaque slot renders a visible debug stub
    /// (instead of `EmptyView`), which is what the tests assert against.
    public var showOpaqueStubs: Bool
    /// Re-evaluates a `geometryReader`'s child body against the live proxy (see
    /// `GeometryRebuild`). When nil, a `geometryReader` renders its static children.
    public var geometryRebuild: GeometryRebuild?
    public init(actions: ActionTable = ActionTable(),
                opaques: OpaqueTable = OpaqueTable(),
                tokens: HostTokenTable = HostTokenTable(),
                dispatcher: Dispatcher? = nil,
                showOpaqueStubs: Bool = true,
                geometryRebuild: GeometryRebuild? = nil) {
        self.actions = actions
        self.opaques = opaques
        self.tokens = tokens
        self.dispatcher = dispatcher
        self.showOpaqueStubs = showOpaqueStubs
        self.geometryRebuild = geometryRebuild
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
        // List editing: `.onDelete`/`.onMove` are ForEach (`DynamicViewContent`)
        // methods, so they must attach to a REAL ForEach (not a type-erased AnyView).
        // When a `.forEach` node carries them, render its rows through a real ForEach
        // here and attach the handlers; the rest of the modifiers replay normally.
        if case .forEach(let children) = node.kind {
            let deleteEvent = node.modifiers.compactMap { m -> EventID? in
                if case .onDelete(let e) = m { return e }; return nil
            }.first
            let moveEvent = node.modifiers.compactMap { m -> EventID? in
                if case .onMove(let e) = m { return e }; return nil
            }.first
            if deleteEvent != nil || moveEvent != nil {
                let base = editableForEach(children, onDelete: deleteEvent, onMove: moveEvent)
                let rest = node.modifiers.filter {
                    if case .onDelete = $0 { return false }; if case .onMove = $0 { return false }
                    return true
                }
                return applyModifiers(rest, to: base)
            }
        }
        // A Shape/path node carrying `.stroke`/`.strokeBorder` renders as an UNFILLED
        // outline (not the default FILLED shape with a stroke overlaid — which paints
        // the fill, default-foreground/black, under the outline). `.fill` stays on the
        // default filled path (already correct).
        if let outlined = strokedShapeIfNeeded(node) { return outlined }
        let base = renderKind(node.kind)
        return applyModifiers(node.modifiers, to: base)
    }

    /// If `node` is a `.shape`/`.path` carrying `.stroke`/`.strokeBorder`, render the
    /// UNFILLED stroked outline — `stroke(style:)` (iOS 13+) gives the outline shape and
    /// `foregroundStyle` (iOS 15+) colors it (avoids the iOS-17-only `stroke(_:style:)`).
    /// Returns nil for non-shape nodes or shapes without a stroke modifier.
    /// The concrete `AnyShape` for a `.shape`/`.path` node, with a `.trim(from:to:)`
    /// modifier applied (the progress-ring idiom). Returns nil for a non-shape node.
    private func baseShape(for node: ViewNode) -> AnyShape? {
        var baseShape: AnyShape
        switch node.kind {
        case .shape(let k): baseShape = shapeValue(k)
        case .path(let cmds): baseShape = AnyShape(buildPath(cmds))
        default: return nil
        }
        // `Shape.trim(from:to:)` — trim the path BEFORE stroke/fill (so a progress
        // ring's input drives the arc). Trim returns an opaque Shape; re-erase it.
        for m in node.modifiers {
            if case .trim(let from, let to) = m {
                baseShape = AnyShape(baseShape.trim(from: CGFloat(from), to: CGFloat(to)))
            }
        }
        return baseShape
    }

    private func strokedShapeIfNeeded(_ node: ViewNode) -> AnyView? {
        guard let baseShape = baseShape(for: node) else { return nil }
        let strokeMod = node.modifiers.first { m in
            if case .stroke = m { return true }; if case .strokeBorder = m { return true }; return false
        }
        // No stroke, but a trim is present + the node IS a shape: render the trimmed
        // shape (filled by a `.fill`/`.foregroundColor` modifier, or default fill).
        // Without this a `Circle().trim(...).fill(...)` would lose the trim (the
        // default fill path rebuilds the UNtrimmed shape from `renderKind`).
        let hasTrim = node.modifiers.contains { if case .trim = $0 { return true }; return false }
        guard let strokeMod else {
            if hasTrim {
                let rest = node.modifiers.filter { if case .trim = $0 { return false }; return true }
                return applyModifiers(rest, to: AnyView(baseShape))
            }
            return nil
        }
        let s: IRShapeStyle, st: IRStrokeStyle
        switch strokeMod {
        case .stroke(let style, let stroke), .strokeBorder(let style, let stroke): s = style; st = stroke
        default: return nil
        }
        let outline = AnyView(baseShape.stroke(style: strokeStyle(st)).foregroundStyle(renderShapeStyle(s)))
        let rest = node.modifiers.filter { m in
            if case .stroke = m { return false }; if case .strokeBorder = m { return false }
            if case .trim = m { return false }   // already applied to baseShape
            return true
        }
        return applyModifiers(rest, to: outline)
    }

    /// A real `ForEach` over the unrolled rows with `.onDelete`/`.onMove` attached.
    /// `onDelete` dispatches `.array([.int])` of the deleted offsets; `onMove`
    /// dispatches `.array([.int])` = `[source₀, source₁, …, destination]`.
    private func editableForEach(_ nodes: [ViewNode], onDelete: EventID?, onMove: EventID?) -> AnyView {
        var fe = ForEach(Array(nodes.enumerated()), id: \.offset) { _, child in
            self.render(child)
        }
        .onDelete { [d = context.dispatcher] indexSet in
            if let onDelete { d?.send(onDelete, .array(indexSet.sorted().map { .int($0) })) }
        }
        // `.onMove` returns an opaque `DynamicViewContent`; chain it conditionally.
        _ = fe
        if let onMove {
            let moved = ForEach(Array(nodes.enumerated()), id: \.offset) { _, child in
                self.render(child)
            }
            .onDelete { [d = context.dispatcher] indexSet in
                if let onDelete { d?.send(onDelete, .array(indexSet.sorted().map { .int($0) })) }
            }
            .onMove { [d = context.dispatcher] source, destination in
                var payload = source.sorted().map { IRValue.int($0) }
                payload.append(.int(destination))
                d?.send(onMove, .array(payload))
            }
            return AnyView(moved)
        }
        return AnyView(fe)
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

        case .styledText(let s, let verbatim, let markdown, let localized):
            return AnyView(styledText(s, verbatim: verbatim, markdown: markdown, localized: localized))

        case .dateText(let epoch, let style):
            let date = Date(timeIntervalSince1970: epoch)
            switch style {
            case .date: return AnyView(Text(date, style: .date))
            case .time: return AnyView(Text(date, style: .time))
            case .relative: return AnyView(Text(date, style: .relative))
            case .offset: return AnyView(Text(date, style: .offset))
            case .timer: return AnyView(Text(date, style: .timer))
            }

        case .image(let systemName):
            return AnyView(Image(systemName: systemName))

        case .symbolImage(let systemName, let variableValue):
            if let vv = variableValue {
                #if os(iOS) || os(macOS) || os(tvOS) || os(watchOS) || os(visionOS)
                if #available(iOS 16, macOS 13, tvOS 16, watchOS 9, *) {
                    return AnyView(Image(systemName: systemName, variableValue: vv))
                }
                #endif
            }
            return AnyView(Image(systemName: systemName))

        case .bundleImage(let name):
            // Resolve the shipped Asset Catalog by name (the bytes are in the
            // bundle). If the name doesn't resolve, SwiftUI renders nothing — which
            // is the same as the native `Image(name)` behavior.
            return AnyView(Image(name))

        case .asyncImage(let url, let scale):
            if let u = URL(string: url) {
                if let scale { return AnyView(AsyncImage(url: u, scale: CGFloat(scale))) }
                return AnyView(AsyncImage(url: u))
            }
            return AnyView(Color.clear)

        case .spacer(let minLength):
            if let m = minLength { return AnyView(Spacer(minLength: m)) }
            return AnyView(Spacer())

        case .divider:
            return AnyView(Divider())

        case .color(let c):
            return AnyView(color(c))

        case .shape(let s):
            return AnyView(shape(s))

        case .path(let commands):
            return AnyView(buildPath(commands))

        case .progressView:
            // An indeterminate spinner. The value/label forms stay opaque, so a
            // bare ProgressView() is all this kind ever carries.
            return AnyView(ProgressView())

        case .determinateProgress(let value, let total, let label):
            if label.isEmpty {
                return AnyView(ProgressView(value: value, total: total))
            }
            return AnyView(ProgressView(value: value, total: total) { renderChildren(label) })

        case .gauge(let data, let label):
            // `Gauge` is iOS 16+/macOS 13+/watchOS 9+; degrade to a determinate
            // ProgressView (value/total) where it's unavailable (incl. tvOS, which
            // has no Gauge at all).
            #if os(tvOS)
            return AnyView(ProgressView(value: data.value - data.min,
                                        total: max(0.0001, data.max - data.min)))
            #else
            if #available(iOS 16, macOS 13, watchOS 9, *) {
                if label.isEmpty {
                    return AnyView(Gauge(value: data.value, in: data.min...data.max) { EmptyView() })
                }
                return AnyView(Gauge(value: data.value, in: data.min...data.max) { renderChildren(label) })
            }
            return AnyView(ProgressView(value: data.value - data.min,
                                        total: max(0.0001, data.max - data.min)))
            #endif

        case .link(let destination, let label):
            // `Link` needs a valid URL; if the destination doesn't parse, render the
            // label inert rather than trap.
            if let u = URL(string: destination) {
                return AnyView(Link(destination: u) { renderChildren(label) })
            }
            return renderChildren(label)

        case .shareLink(let items, let label):
            // The built-in share sheet. `items` are strings (URLs/text). iOS 16+/
            // macOS 13+/watchOS 9+; degrade to the label content where unavailable
            // (tvOS has no ShareLink).
            #if os(tvOS)
            return renderChildren(label)
            #else
            if #available(iOS 16, macOS 13, watchOS 9, *) {
                let payload = items.joined(separator: "\n")
                if label.isEmpty {
                    return AnyView(ShareLink(item: payload))
                }
                return AnyView(ShareLink(item: payload) { renderChildren(label) })
            }
            return renderChildren(label)
            #endif

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

        // MARK: Containers — IR v2 (more of a real screen rides WASM).

        case .scrollView(let axis, let children):
            let set: Axis.Set = (axis == .horizontal) ? .horizontal : .vertical
            return AnyView(
                ScrollView(set) { renderChildren(children) }
            )

        case .list(let children):
            return AnyView(
                List { renderChildren(children) }
            )

        case .section(let header, let footer, let content):
            // SwiftUI's `Section(content:header:footer:)`. Empty header/footer
            // arrays render no header/footer (an `EmptyView` is a no-op there).
            return AnyView(
                Section {
                    renderChildren(content)
                } header: {
                    renderChildren(header)
                } footer: {
                    renderChildren(footer)
                }
            )

        case .form(let children):
            return AnyView(
                Form { renderChildren(children) }
            )

        case .navigationStack(let children):
            // `NavigationStack` is unavailable on older OSes / some platforms
            // (watchOS). Fall back to the children directly so a navigation
            // shell never fails to render (the title modifier degrades too).
            #if os(watchOS)
            return renderChildren(children)
            #else
            if #available(iOS 16, macOS 13, tvOS 16, *) {
                return AnyView(NavigationStack { renderChildren(children) })
            }
            return renderChildren(children)
            #endif

        // MARK: Containers — leaf-views + container expansion.

        case .lazyVStack(let alignment, let spacing, let children):
            return AnyView(
                LazyVStack(alignment: horizontal(alignment), spacing: spacing.map { CGFloat($0) }) {
                    renderChildren(children)
                }
            )

        case .lazyHStack(let alignment, let spacing, let children):
            return AnyView(
                LazyHStack(alignment: vertical(alignment), spacing: spacing.map { CGFloat($0) }) {
                    renderChildren(children)
                }
            )

        case .lazyVGrid(let columns, let spacing, let children):
            return AnyView(
                LazyVGrid(columns: gridItems(columns), spacing: spacing.map { CGFloat($0) }) {
                    renderChildren(children)
                }
            )

        case .lazyHGrid(let rows, let spacing, let children):
            return AnyView(
                LazyHGrid(rows: gridItems(rows), spacing: spacing.map { CGFloat($0) }) {
                    renderChildren(children)
                }
            )

        case .grid(let alignment, let hSpacing, let vSpacing, let children):
            // `Grid` is iOS 16+/macOS 13+/tvOS 16+/watchOS 9+; degrade to a VStack of
            // the rows (each `gridRow` already renders as an HStack — see below).
            if #available(iOS 16, macOS 13, tvOS 16, watchOS 9, *) {
                return AnyView(
                    Grid(alignment: zalignment(alignment),
                         horizontalSpacing: hSpacing.map { CGFloat($0) },
                         verticalSpacing: vSpacing.map { CGFloat($0) }) {
                        renderChildren(children)
                    }
                )
            }
            return AnyView(VStack(alignment: .center) { renderChildren(children) })

        case .gridRow(let alignment, let children):
            if #available(iOS 16, macOS 13, tvOS 16, watchOS 9, *) {
                return AnyView(GridRow(alignment: vertical(alignment)) { renderChildren(children) })
            }
            // Outside a Grid (or pre-16) a row is just a horizontal run.
            return AnyView(HStack(alignment: vertical(alignment)) { renderChildren(children) })

        case .groupBox(let label, let children):
            // `GroupBox` is iOS 14+/macOS 11+ but NOT on tvOS/watchOS — degrade to a
            // VStack (label over content) there.
            #if os(tvOS) || os(watchOS)
            return AnyView(VStack(alignment: .leading) {
                renderChildren(label); renderChildren(children)
            })
            #else
            if label.isEmpty {
                return AnyView(GroupBox { renderChildren(children) })
            }
            return AnyView(GroupBox {
                renderChildren(children)
            } label: {
                renderChildren(label)
            })
            #endif

        case .disclosureGroup(let label, let children):
            // UNBOUND DisclosureGroup — SwiftUI owns the expand/collapse state.
            // Unavailable on tvOS; degrade to label-over-content.
            #if os(tvOS)
            return AnyView(VStack(alignment: .leading) {
                renderChildren(label); renderChildren(children)
            })
            #else
            return AnyView(
                DisclosureGroup {
                    renderChildren(children)
                } label: {
                    renderChildren(label)
                }
            )
            #endif

        case .viewThatFits(let axes, let children):
            // `ViewThatFits` is iOS 16+/macOS 13+/tvOS 16+/watchOS 9+; degrade to the
            // first candidate (SwiftUI would pick a candidate; the first is the
            // "largest"/preferred) where unavailable.
            if #available(iOS 16, macOS 13, tvOS 16, watchOS 9, *) {
                switch axes {
                case .both:
                    return AnyView(ViewThatFits { renderChildren(children) })
                case .horizontal:
                    return AnyView(ViewThatFits(in: .horizontal) { renderChildren(children) })
                case .vertical:
                    return AnyView(ViewThatFits(in: .vertical) { renderChildren(children) })
                }
            }
            return render(children.first ?? ViewNode(.group(children: [])))

        case .controlGroup(let children):
            // `ControlGroup` is iOS 16+/macOS 13+ (not tvOS/watchOS) — degrade to an
            // HStack of the controls.
            #if os(tvOS) || os(watchOS)
            return AnyView(HStack { renderChildren(children) })
            #else
            if #available(iOS 16, macOS 13, *) {
                return AnyView(ControlGroup { renderChildren(children) })
            }
            return AnyView(HStack { renderChildren(children) })
            #endif

        case .tabView(let tabs, let style):
            return AnyView(tabView(tabs: tabs, style: style))

        case .button(let actionID, let role, let label):
            let action = context.actions.action(for: actionID) ?? {}
            if let role {
                return AnyView(
                    Button(role: buttonRole(role), action: action) { renderChildren(label) }
                )
            }
            return AnyView(
                Button(action: action) { renderChildren(label) }
            )

        case .label(let title, let icon):
            // The GENERAL `Label { title } icon: { icon }` — both are subtrees so a
            // custom title/icon recurses. (The convenience builder emits a Text title
            // + an SF-symbol Image icon.)
            return AnyView(
                Label {
                    renderChildren(title)
                } icon: {
                    renderChildren(icon)
                }
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

        case .secureField(let placeholder, let value, let event):
            let binding = Binding<String>(
                get: { value },
                set: { [d = context.dispatcher] new in d?.send(event, .string(new)) }
            )
            return AnyView(SecureField(placeholder, text: binding))

        case .textEditor(let value, let event):
            // `TextEditor` is iOS 14+/macOS 11+ but unavailable on tvOS/watchOS —
            // degrade to a TextField there (same binding).
            let binding = Binding<String>(
                get: { value },
                set: { [d = context.dispatcher] new in d?.send(event, .string(new)) }
            )
            #if os(tvOS) || os(watchOS)
            return AnyView(TextField("", text: binding))
            #else
            return AnyView(TextEditor(text: binding))
            #endif

        case .labeledContent(let label, let content):
            // `LabeledContent` is iOS 16+/macOS 13+/tvOS 16+/watchOS 9+; degrade to an
            // HStack (label, spacer, content) where unavailable.
            if #available(iOS 16, macOS 13, tvOS 16, watchOS 9, *) {
                return AnyView(
                    LabeledContent {
                        renderChildren(content)
                    } label: {
                        renderChildren(label)
                    }
                )
            }
            return AnyView(HStack { renderChildren(label); Spacer(); renderChildren(content) })

        case .menu(let label, let items):
            // `Menu` is iOS 14+/macOS 11+/tvOS 17+, NOT watchOS — degrade to the items
            // inline on watchOS and pre-17 tvOS. The item Buttons auto-wire via the
            // actionID path.
            #if os(watchOS)
            return AnyView(VStack { renderChildren(items) })
            #elseif os(tvOS)
            if #available(tvOS 17, *) {
                return AnyView(Menu { renderChildren(items) } label: { renderChildren(label) })
            }
            return AnyView(VStack { renderChildren(label); renderChildren(items) })
            #else
            return AnyView(
                Menu {
                    renderChildren(items)
                } label: {
                    renderChildren(label)
                }
            )
            #endif

        case .contextMenu(let content, let items):
            // Attach a `.contextMenu { items }` to the content. The menu items
            // (Buttons) auto-wire via the actionID path.
            return AnyView(
                renderChildren(content).contextMenu {
                    renderChildren(items)
                }
            )

        // MARK: Host-state controls — real SwiftUI selection/nav bound to dispatch.

        case .picker(let label, let selection, let kind, let options, let event):
            return AnyView(picker(label: label, selection: selection, kind: kind,
                                  options: options, event: event))

        case .datePicker(let label, let epoch, let components, let minE, let maxE, let event):
            // `DatePicker` is unavailable on tvOS; degrade to its label there.
            #if os(tvOS)
            _ = (epoch, components, minE, maxE, event)
            return AnyView(renderChildren(label))
            #else
            let binding = Binding<Date>(
                get: { Date(timeIntervalSince1970: epoch) },
                set: { [d = context.dispatcher] new in d?.send(event, .double(new.timeIntervalSince1970)) }
            )
            return AnyView(datePicker(label: label, selection: binding,
                                      components: components, minE: minE, maxE: maxE))
            #endif

        case .colorPicker(let label, let color, let supportsOpacity, let event):
            // `ColorPicker` is iOS 14+/macOS 11+ only (no tvOS/watchOS) — degrade to
            // the label there. The color crosses as RGBA components.
            #if os(iOS) || os(macOS) || os(visionOS)
            let binding = Binding<Color>(
                get: { Color(.sRGB, red: color.r, green: color.g, blue: color.b, opacity: color.a) },
                set: { [d = context.dispatcher] new in
                    let c = Self.rgbaComponents(new)
                    d?.send(event, .array([.double(c.0), .double(c.1), .double(c.2), .double(c.3)]))
                }
            )
            return AnyView(ColorPicker(selection: binding, supportsOpacity: supportsOpacity) {
                renderChildren(label)
            })
            #else
            _ = (color, supportsOpacity, event)
            return AnyView(renderChildren(label))
            #endif

        case .navigationLink(let destination, let label):
            // The EAGER form — SwiftUI owns push/pop; both subtrees recurse.
            #if os(watchOS)
            return AnyView(NavigationLink { renderChildren(destination) } label: { renderChildren(label) })
            #else
            if #available(iOS 16, macOS 13, tvOS 16, *) {
                return AnyView(NavigationLink { renderChildren(destination) } label: { renderChildren(label) })
            }
            return AnyView(NavigationLink(destination: renderChildren(destination)) { renderChildren(label) })
            #endif

        case .navigationStackPath(let path, let root, let destinations, let event):
            return AnyView(navigationStackPath(path: path, root: root,
                                               destinations: destinations, event: event))

        case .boundDisclosureGroup(let label, let isExpanded, let content, let event):
            // BOUND DisclosureGroup — the SDK owns the expand/collapse via a binding
            // whose GET is the guest flag, SET dispatches. (Unavailable on tvOS.)
            #if os(tvOS)
            _ = (isExpanded, event)
            return AnyView(VStack(alignment: .leading) { renderChildren(label); renderChildren(content) })
            #else
            let binding = Binding<Bool>(
                get: { isExpanded },
                set: { [d = context.dispatcher] new in d?.send(event, .bool(new)) }
            )
            return AnyView(
                DisclosureGroup(isExpanded: binding) {
                    renderChildren(content)
                } label: {
                    renderChildren(label)
                }
            )
            #endif

        case .boundSection(let header, let isExpanded, let content, let event):
            // `Section(isExpanded:)` is iOS 17+/macOS 14+; degrade to a plain Section
            // (header over content) where unavailable.
            if #available(iOS 17, macOS 14, tvOS 17, watchOS 10, visionOS 1, *) {
                let binding = Binding<Bool>(
                    get: { isExpanded },
                    set: { [d = context.dispatcher] new in d?.send(event, .bool(new)) }
                )
                return AnyView(
                    Section(isExpanded: binding) {
                        renderChildren(content)
                    } header: {
                        renderChildren(header)
                    }
                )
            }
            _ = (isExpanded, event)
            return AnyView(Section { renderChildren(content) } header: { renderChildren(header) })

        case .boundTabView(let selection, let kind, let tabs, let style, let event):
            return AnyView(boundTabView(selection: selection, kind: kind, tabs: tabs,
                                        style: style, event: event))

        case .editButton:
            // A real stdlib `EditButton` — toggles the environment's `EditMode`
            // (which `EditModeHost`, below, owns when present). Unavailable on
            // macOS/tvOS/watchOS — degrade to EmptyView there.
            #if os(iOS) || os(visionOS)
            return AnyView(EditButton())
            #else
            return AnyView(EmptyView())
            #endif

        case .geometryReader(let id, let children):
            // A REAL `GeometryReader { proxy in … }`. The wrapper injects the live
            // proxy's size/frame as reserved `__geo_*` inputs and re-evaluates the
            // lowered child body on each size change (via `context.geometryRebuild`);
            // when no rebuild closure is wired (e.g. a direct `render(_:)`), it renders
            // the statically-lowered `children` (correct for their emit-time size).
            return AnyView(GeometryReaderHost(
                id: id, staticChildren: children,
                rebuild: context.geometryRebuild,
                renderChildren: { self.renderChildren($0) }))

        case .canvas(let ops):
            // A REAL `Canvas` replaying the serialized draw ops via the in-binary
            // `GraphicsContext` (no native draw code). `Canvas` is iOS 15+/macOS 12+/
            // tvOS 15+/watchOS 8+; degrade to EmptyView where unavailable.
            return canvasView(ops)

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
        case .fontToken(let id):
            // A design-system font token: apply the host-supplied `Font` from the
            // thunk's `__patchTokens()`. If none was supplied (PatchedBodyHost would
            // normally have demoted), leave the inherited font — never a wrong font.
            if let f = context.tokens.font(for: id) { return AnyView(v.font(f)) }
            return v
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
        case .navigationTitle(let title):
            // `.navigationTitle(_:)` is unavailable on macOS pre-11 and some
            // platforms; the String overload is the broadly-available form. On
            // platforms without it the modifier degrades to a no-op.
            #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
            return AnyView(v.navigationTitle(title))
            #elseif os(macOS)
            if #available(macOS 11, *) { return AnyView(v.navigationTitle(title)) }
            return v
            #else
            return v
            #endif
        case .flexFrame(let minW, let idealW, let maxW, let minH, let idealH, let maxH, let a):
            // A flexible frame: each bound is an `IRLength?` mapped to `CGFloat?`
            // (`.infinity` → `CGFloat.infinity`, `.points` → its CGFloat, nil → nil),
            // matching SwiftUI's flexible `.frame(...)` overload exactly.
            return AnyView(v.frame(minWidth: cg(minW), idealWidth: cg(idealW), maxWidth: cg(maxW),
                                   minHeight: cg(minH), idealHeight: cg(idealH), maxHeight: cg(maxH),
                                   alignment: zalignment(a)))
        case .tint(let c):
            return AnyView(v.tint(color(c)))
        case .clipShape(let k):
            return AnyView(v.clipShape(shapeValue(k)))
        case .trim:
            // `Shape.trim(from:to:)` is a Shape method, applied to the concrete
            // `AnyShape` in `baseShape(for:)` (the shape render path). On a
            // type-erased non-Shape view there's no analogue — faithful no-op.
            return v
        case .disabled(let b):
            return AnyView(v.disabled(b))
        case .fixedSize:
            return AnyView(v.fixedSize())

        // MARK: Styling (unified IRShapeStyle vocabulary)
        case .foregroundStyle(let layers):
            return applyForegroundStyle(layers, to: v)
        case .backgroundContent(let a, let content):
            return AnyView(v.background(alignment: zalignment(a)) { renderChildren(content) })
        case .backgroundStyle(let s, let shape):
            if let shape {
                return AnyView(v.background(renderShapeStyle(s), in: shapeValue(shape)))
            }
            return AnyView(v.background(renderShapeStyle(s)))
        case .tintStyle(let s):
            return AnyView(v.tint(renderShapeStyle(s)))
        case .fill(let s, _):
            // A Shape rendered as a view fills via `.foregroundStyle` (exactly what
            // `Shape.fill(_:)` does); the eoFill rule has no View-level analogue.
            return AnyView(v.foregroundStyle(renderShapeStyle(s)))
        case .stroke(let s, let st), .strokeBorder(let s, let st):
            // `.stroke`/`.strokeBorder` are Shape methods; a Shape NODE carrying these
            // is handled exactly at the Shape level in `strokedShapeIfNeeded`. On a
            // type-erased (non-Shape) view we overlay a stroked rectangle of the view's
            // bounds. `stroke(style:)`+`foregroundStyle` is cross-version (avoids the
            // iOS-17-only `strokeBorder(_:style:)`/`stroke(_:style:)` content overloads).
            return AnyView(v.overlay(
                Rectangle().stroke(style: strokeStyle(st)).foregroundStyle(renderShapeStyle(s))))
        case .border(let s, let w):
            return AnyView(v.border(renderShapeStyle(s), width: CGFloat(w)))
        case .overlayContent(let a, let content):
            return AnyView(v.overlay(alignment: zalignment(a)) { renderChildren(content) })
        case .overlayStyle(let s, let shape):
            return AnyView(v.overlay(renderShapeStyle(s), in: shapeValue(shape)))
        case .shadow(let c, let r, let x, let y):
            if let c {
                return AnyView(v.shadow(color: color(c), radius: CGFloat(r), x: CGFloat(x), y: CGFloat(y)))
            }
            return AnyView(v.shadow(radius: CGFloat(r), x: CGFloat(x), y: CGFloat(y)))
        case .mask(let a, let content):
            return AnyView(v.mask(alignment: zalignment(a)) { renderChildren(content) })

        // MARK: Layout
        case .offset(let x, let y):
            return AnyView(v.offset(x: CGFloat(x), y: CGFloat(y)))
        case .position(let x, let y):
            return AnyView(v.position(x: CGFloat(x), y: CGFloat(y)))
        case .aspectRatio(let ratio, let mode):
            return AnyView(v.aspectRatio(ratio.map { CGFloat($0) }, contentMode: contentMode(mode)))
        case .clipped(let aa):
            return AnyView(v.clipped(antialiased: aa))
        case .fixedSizeAxis(let h, let vv):
            return AnyView(v.fixedSize(horizontal: h, vertical: vv))
        case .layoutPriority(let p):
            return AnyView(v.layoutPriority(p))
        case .safeAreaInset(let edge, let a, let spacing, let content):
            return applySafeAreaInset(edge: edge, alignment: a, spacing: spacing, content: content, to: v)
        case .ignoresSafeArea(let regions, let edges):
            return AnyView(v.ignoresSafeArea(safeAreaRegions(regions), edges: edgeSet(edges)))
        case .zIndex(let z):
            return AnyView(v.zIndex(z))
        case .containerRelativeFrame(let axes, let a):
            #if os(watchOS)
            return v
            #else
            if #available(iOS 17, macOS 14, tvOS 17, watchOS 10, visionOS 1, *) {
                return AnyView(v.containerRelativeFrame(axisSet(axes), alignment: zalignment(a)))
            }
            return v
            #endif
        case .allowsHitTesting(let b):
            return AnyView(v.allowsHitTesting(b))
        case .scrollClipDisabled(let b):
            // `.scrollClipDisabled(_:)` is iOS 17+; older OS → no-op (faithful).
            if #available(iOS 17, macOS 14, tvOS 17, watchOS 10, visionOS 1, *) {
                return AnyView(v.scrollClipDisabled(b))
            }
            return v
        case .scrollContentBackground(let vis):
            // `.scrollContentBackground(_:)` is iOS 16+; older OS → no-op (faithful).
            if #available(iOS 16, macOS 13, tvOS 16, watchOS 9, visionOS 1, *) {
                return AnyView(v.scrollContentBackground(titleVisibility(vis)))
            }
            return v
        case .listRowSeparator(let vis, let edges):
            #if os(iOS) || os(macOS) || os(visionOS)
            if #available(iOS 15, macOS 13, *) {
                return AnyView(v.listRowSeparator(titleVisibility(vis), edges: verticalEdgeSet(edges)))
            }
            return v
            #else
            _ = (vis, edges); return v
            #endif
        case .listRowBackground(let content):
            return AnyView(v.listRowBackground(renderChildren(content)))
        case .listRowInsets(let i):
            return AnyView(v.listRowInsets(edgeInsets(i)))
        case .listSectionSeparator(let vis, let edges):
            #if os(iOS) || os(macOS) || os(visionOS)
            if #available(iOS 15, macOS 13, *) {
                return AnyView(v.listSectionSeparator(titleVisibility(vis), edges: verticalEdgeSet(edges)))
            }
            return v
            #else
            _ = (vis, edges); return v
            #endif

        // MARK: Transforms & visual effects
        case .rotationEffect(let d, let anchor):
            return AnyView(v.rotationEffect(.degrees(d), anchor: unitPoint(anchor) ?? .center))
        case .rotation3DEffect(let d, let x, let y, let z, let anchor, let az, let p):
            return AnyView(v.rotation3DEffect(.degrees(d), axis: (x: CGFloat(x), y: CGFloat(y), z: CGFloat(z)),
                                              anchor: unitPoint(anchor) ?? .center,
                                              anchorZ: CGFloat(az), perspective: CGFloat(p)))
        case .scaleEffect(let x, let y, let anchor):
            return AnyView(v.scaleEffect(x: CGFloat(x), y: CGFloat(y), anchor: unitPoint(anchor) ?? .center))
        case .blur(let r, let opaque):
            return AnyView(v.blur(radius: CGFloat(r), opaque: opaque))
        case .brightness(let val):
            return AnyView(v.brightness(val))
        case .contrast(let val):
            return AnyView(v.contrast(val))
        case .saturation(let val):
            return AnyView(v.saturation(val))
        case .grayscale(let val):
            return AnyView(v.grayscale(val))
        case .hueRotation(let d):
            return AnyView(v.hueRotation(.degrees(d)))
        case .colorInvert:
            return AnyView(v.colorInvert())
        case .blendMode(let m):
            return AnyView(v.blendMode(blendMode(m)))

        // MARK: Text styling
        case .fontWeight(let w):
            return AnyView(v.fontWeight(w.map { weight($0) }))
        case .fontDesign(let d):
            #if os(watchOS)
            return AnyView(v.fontDesign(design(d)))
            #else
            if #available(iOS 16.1, macOS 13, tvOS 16.1, watchOS 9.1, visionOS 1, *) {
                return AnyView(v.fontDesign(d.map { design($0) }))
            }
            return v
            #endif
        case .underline(let active, let c):
            if #available(iOS 16, macOS 13, tvOS 16, watchOS 9, visionOS 1, *) {
                return AnyView(v.underline(active, color: c.map { color($0) }))
            }
            return v
        case .strikethrough(let active, let c):
            if #available(iOS 16, macOS 13, tvOS 16, watchOS 9, visionOS 1, *) {
                return AnyView(v.strikethrough(active, color: c.map { color($0) }))
            }
            return v
        case .kerning(let val):
            if #available(iOS 16, macOS 13, tvOS 16, watchOS 9, visionOS 1, *) {
                return AnyView(v.kerning(CGFloat(val)))
            }
            return v
        case .tracking(let val):
            if #available(iOS 16, macOS 13, tvOS 16, watchOS 9, visionOS 1, *) {
                return AnyView(v.tracking(CGFloat(val)))
            }
            return v
        case .baselineOffset(let val):
            if #available(iOS 16, macOS 13, tvOS 16, watchOS 9, visionOS 1, *) {
                return AnyView(v.baselineOffset(CGFloat(val)))
            }
            return v
        case .lineSpacing(let val):
            return AnyView(v.lineSpacing(CGFloat(val)))
        case .textCase(let c):
            return AnyView(v.textCase(textCase(c)))
        case .minimumScaleFactor(let val):
            return AnyView(v.minimumScaleFactor(CGFloat(val)))
        case .truncationMode(let m):
            return AnyView(v.truncationMode(truncationMode(m)))
        case .monospaced:
            if #available(iOS 15, macOS 12, tvOS 15, watchOS 8, visionOS 1, *) {
                return AnyView(v.monospaced())
            }
            return v
        case .monospacedDigit:
            return AnyView(v.monospacedDigit())
        case .redacted(let reason):
            return AnyView(v.redacted(reason: redactionReason(reason)))
        case .unredacted:
            return AnyView(v.unredacted())
        case .symbolRenderingMode(let m):
            return AnyView(v.symbolRenderingMode(symbolRenderingMode(m)))
        case .symbolVariant(let variant):
            return AnyView(v.symbolVariant(symbolVariant(variant)))
        case .imageScale(let s):
            return AnyView(v.imageScale(imageScale(s)))
        case .dynamicTypeSize(let s):
            if #available(iOS 15, macOS 12, tvOS 15, watchOS 8, visionOS 1, *) {
                return AnyView(v.dynamicTypeSize(dynamicTypeSize(s)))
            }
            return v

        // MARK: Control config (built-in named styles)
        case .buttonStyle(let s):
            return applyButtonStyle(s, to: v)
        case .listStyle(let s):
            return applyListStyle(s, to: v)
        case .pickerStyle(let s):
            return applyPickerStyle(s, to: v)
        case .toggleStyle(let s):
            return applyToggleStyle(s, to: v)
        case .labelStyle(let s):
            return applyLabelStyle(s, to: v)
        case .gaugeStyle, .menuStyle:
            // Built-in gauge/menu styles are niche + version-gated; carry the intent
            // but degrade to no-op rather than risk an unavailable static.
            return v
        case .progressViewStyle(let s):
            return applyProgressViewStyle(s, to: v)
        case .buttonBorderShape(let s):
            return applyButtonBorderShape(s, to: v)
        case .controlSize(let s):
            return applyControlSize(s, to: v)
        case .tabViewStyle(let s):
            return applyTabViewStyle(s, to: v)
        case .indexViewStyle(let s):
            return applyIndexViewStyle(s, to: v)
        case .keyboardType(let s):
            #if os(iOS) || os(tvOS) || os(visionOS)
            return AnyView(v.keyboardType(keyboardType(s)))
            #else
            return v
            #endif
        case .textContentType(let s):
            #if os(iOS) || os(tvOS) || os(visionOS)
            return AnyView(v.textContentType(textContentType(s)))
            #else
            return v
            #endif
        case .autocorrectionDisabled(let b):
            if #available(iOS 15, macOS 12, tvOS 15, watchOS 8, visionOS 1, *) {
                return AnyView(v.autocorrectionDisabled(b))
            }
            return v
        case .textInputAutocapitalization(let s):
            #if os(iOS) || os(tvOS) || os(visionOS)
            if #available(iOS 15, tvOS 15, visionOS 1, *) {
                return AnyView(v.textInputAutocapitalization(textAutocap(s)))
            }
            return v
            #else
            return v
            #endif
        case .submitLabel(let s):
            if #available(iOS 15, macOS 12, tvOS 15, watchOS 8, visionOS 1, *) {
                return AnyView(v.submitLabel(submitLabel(s)))
            }
            return v
        case .preferredColorScheme(let s):
            return AnyView(v.preferredColorScheme(colorScheme(s)))
        case .accentColor(let c):
            return AnyView(v.tint(c.map { color($0) }))   // accentColor is deprecated → tint

        // MARK: Gestures
        case .onLongPressGesture(let minDur, let e):
            #if os(tvOS)
            _ = (minDur, e); return v
            #else
            return AnyView(v.onLongPressGesture(minimumDuration: minDur) {
                [d = context.dispatcher] in d?.send(e, .none)
            })
            #endif
        case .dragGesture(let minDist, let onChanged, let onEnded):
            return applyDragGesture(minDistance: minDist, onChanged: onChanged, onEnded: onEnded, to: v)
        case .magnifyGesture(let e):
            #if os(iOS) || os(macOS) || os(visionOS)
            if #available(iOS 17, macOS 14, visionOS 1, *) {
                return AnyView(v.gesture(MagnifyGesture()
                    .onChanged { [d = context.dispatcher] val in d?.send(e, .double(Double(val.magnification))) }))
            }
            return v
            #else
            return v
            #endif
        case .rotateGesture(let e):
            #if os(iOS) || os(macOS) || os(visionOS)
            if #available(iOS 17, macOS 14, visionOS 1, *) {
                return AnyView(v.gesture(RotateGesture()
                    .onChanged { [d = context.dispatcher] val in d?.send(e, .double(val.rotation.radians)) }))
            }
            return v
            #else
            return v
            #endif

        // MARK: Lifecycle
        case .onAppear(let e):
            return AnyView(v.onAppear { [d = context.dispatcher] in d?.send(e, .none) })
        case .onDisappear(let e):
            return AnyView(v.onDisappear { [d = context.dispatcher] in d?.send(e, .none) })
        case .onChange(_, let e):
            // The watched value is guest-owned; the host fires the event on the
            // guest's re-emit. We attach a no-trigger onChange so the hook exists;
            // the actual change detection rides the guest dispatch loop. To avoid an
            // availability split on the value type, treat it as a passive hook.
            _ = e
            return v
        case .task(let e, _):
            return AnyView(v.task { [d = context.dispatcher] in d?.send(e, .none) })
        case .onSubmit(let e):
            return AnyView(v.onSubmit { [d = context.dispatcher] in d?.send(e, .none) })
        case .onHover(let e):
            #if os(iOS) || os(macOS) || os(visionOS)
            return AnyView(v.onHover { [d = context.dispatcher] hovering in d?.send(e, .bool(hovering)) })
            #else
            return v
            #endif
        case .sensoryFeedback(let kind, _):
            // The trigger is guest-owned; fire the haptic once when re-rendered is
            // not correct, so degrade to a no-op hook (the trigger semantics need the
            // value bridge). Carrying the case keeps the wire faithful.
            _ = kind
            return v

        // MARK: Animation
        case .animation(let a, _):
            // `.animation(_:value:)` — the value trigger is guest-owned; attaching a
            // value-keyed animation needs the scalar bridge, so we apply the curve as
            // a transaction-free animation is unavailable on a bare view. Degrade to
            // no-op (the guest re-emit drives the visible change). Carrying it keeps
            // the wire faithful + lets a future value-bridge wire it.
            _ = a
            return v
        case .transition(let t):
            return AnyView(v.transition(transition(t)))

        // MARK: Host-state — presentation (B.2)
        // The SDK owns the presentation machinery via a `Binding<Bool>` whose GET
        // returns the guest-emitted flag and whose SET (incl. a system swipe-to-
        // dismiss) dispatches `event` into the guest. Action Buttons inside the
        // content auto-wire via the existing actionID path (handled by PatchedBodyHost).
        case .sheet(_, let isPresented, let content, let event):
            let binding = presentationBinding(isPresented, event)
            return AnyView(v.sheet(isPresented: binding) { renderChildren(content) })
        case .sheetItem(_, let itemPresent, let content, let event):
            // The item's value is already a guest input marshalled into `content`;
            // we bridge presence as a Bool (a swipe-dismiss dispatches `.bool(false)`).
            let binding = presentationBinding(itemPresent, event)
            return AnyView(v.sheet(isPresented: binding) { renderChildren(content) })
        case .fullScreenCover(_, let isPresented, let content, let event):
            // `fullScreenCover` is unavailable on macOS — degrade to `.sheet`.
            #if os(macOS)
            let binding = presentationBinding(isPresented, event)
            return AnyView(v.sheet(isPresented: binding) { renderChildren(content) })
            #else
            let binding = presentationBinding(isPresented, event)
            return AnyView(v.fullScreenCover(isPresented: binding) { renderChildren(content) })
            #endif
        case .popover(_, let isPresented, let content, let event):
            // `popover` is unavailable on tvOS/watchOS — degrade to `.sheet`.
            #if os(tvOS) || os(watchOS)
            let binding = presentationBinding(isPresented, event)
            return AnyView(v.sheet(isPresented: binding) { renderChildren(content) })
            #else
            let binding = presentationBinding(isPresented, event)
            return AnyView(v.popover(isPresented: binding) { renderChildren(content) })
            #endif
        case .alert(let title, _, let isPresented, let actions, let message, let event):
            let binding = presentationBinding(isPresented, event)
            return AnyView(v.alert(title, isPresented: binding) {
                renderChildren(actions)
            } message: {
                renderChildren(message)
            })
        case .confirmationDialog(let title, let tv, _, let isPresented, let actions, let message, let event):
            let binding = presentationBinding(isPresented, event)
            return AnyView(v.confirmationDialog(title, isPresented: binding,
                                                titleVisibility: titleVisibility(tv)) {
                renderChildren(actions)
            } message: {
                renderChildren(message)
            })
        case .navigationDestinationBool(_, let isPresented, let destination, let event):
            // A Bool-bound navigation push (iOS 16+/macOS 13+). Degrade to a `.sheet`
            // where `navigationDestination(isPresented:)` is unavailable.
            #if os(watchOS)
            let binding = presentationBinding(isPresented, event)
            return AnyView(v.sheet(isPresented: binding) { renderChildren(destination) })
            #else
            if #available(iOS 16, macOS 13, tvOS 16, *) {
                let binding = presentationBinding(isPresented, event)
                return AnyView(v.navigationDestination(isPresented: binding) { renderChildren(destination) })
            }
            let binding = presentationBinding(isPresented, event)
            return AnyView(v.sheet(isPresented: binding) { renderChildren(destination) })
            #endif

        // MARK: Host-state — presentation sizing (B.2)
        case .presentationDetents(let detents):
            // `.presentationDetents(_:)` is iOS 16+ / macOS 13+; older OS → no-op.
            if #available(iOS 16, macOS 13, *) {
                let set = presentationDetentSet(detents)
                if !set.isEmpty { return AnyView(v.presentationDetents(set)) }
            }
            return v
        case .presentationDragIndicator(let vis):
            if #available(iOS 16, macOS 13, *) {
                return AnyView(v.presentationDragIndicator(titleVisibility(vis)))
            }
            return v

        // MARK: Host-state — navigation chrome / toolbar (B.2)
        case .toolbar(let items):
            return applyToolbar(items, to: v)
        case .navigationBarTitle(let title, let mode):
            // Legacy `.navigationBarTitle(_, displayMode:)` → the modern equivalents.
            #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
            var nv = AnyView(v)
            if #available(iOS 14, tvOS 14, watchOS 7, *) {
                nv = AnyView(nv.navigationTitle(title)
                    .navigationBarTitleDisplayMode(titleDisplayMode(mode)))
            }
            return nv
            #else
            _ = (title, mode); return v
            #endif
        case .navigationViewStyle(let s):
            return applyNavigationViewStyle(s, to: v)
        case .environmentValue(let key, let value):
            return applyEnvironmentValue(key: key, value: value, to: v)

        // MARK: Accessibility (G8)
        case .accessibilityLabel(let s):
            return AnyView(v.accessibilityLabel(Text(s)))
        case .accessibilityHint(let s):
            return AnyView(v.accessibilityHint(Text(s)))
        case .accessibilityValue(let s):
            return AnyView(v.accessibilityValue(Text(s)))
        case .accessibilityHidden(let b):
            return AnyView(v.accessibilityHidden(b))
        case .accessibilityAddTraits(let s):
            return AnyView(v.accessibilityAddTraits(accessibilityTraits(s)))
        case .accessibilityRemoveTraits(let s):
            return AnyView(v.accessibilityRemoveTraits(accessibilityTraits(s)))
        case .navigationBarTitleDisplayMode(let m):
            #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
            return AnyView(v.navigationBarTitleDisplayMode(titleDisplayMode(m)))
            #else
            return v
            #endif
        case .navigationBarBackButtonHidden(let h):
            #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
            return AnyView(v.navigationBarBackButtonHidden(h))
            #else
            return v
            #endif

        // MARK: Host-state — search / focus (B.2 / B.1)
        case .searchable(_, let query, let prompt, let event):
            // A system search bar bound to the guest's String field (GET=query,
            // SET=dispatch). Unavailable on watchOS/tvOS — degrade to no-op.
            #if os(iOS) || os(macOS) || os(visionOS)
            if #available(iOS 15, macOS 12, *) {
                let binding = Binding<String>(
                    get: { query },
                    set: { [d = context.dispatcher] new in d?.send(event, .string(new)) }
                )
                if let prompt {
                    return AnyView(v.searchable(text: binding, prompt: Text(prompt)))
                }
                return AnyView(v.searchable(text: binding))
            }
            return v
            #else
            _ = (query, prompt, event)
            return v
            #endif
        case .focused(let focusKey, let token, let isFocused, let event):
            // Bind to the SDK-owned `@FocusState<String?>` via a `FocusBinder` wrapper
            // (a View can own a real @FocusState; the Renderer struct can't). GET =
            // the guest's focus token, SET dispatches the new token (or "" unfocused).
            #if os(tvOS)
            _ = (focusKey, token, isFocused, event)
            return v
            #else
            return AnyView(FocusBinder(content: v, fieldToken: token,
                                       isFocused: isFocused,
                                       dispatcher: context.dispatcher, event: event))
            #endif

        // MARK: Host-state — list editing (B.2)
        // `.onDelete`/`.onMove` are `DynamicViewContent` (ForEach) methods, not
        // `View` methods — they can't attach to a type-erased `AnyView`. They're
        // applied at the `.forEach`/`.list` node in `render(_:)` instead (where the
        // real ForEach is in scope); here they're a faithful no-op so the wire stays
        // intact if one lands on a non-ForEach node.
        case .onDelete, .onMove:
            return v

        // MARK: Scroll & layout (sweep — added at END). Each enforces its OS floor;
        // an older OS no-ops faithfully (the modifier had no effect there anyway).
        case .scrollDisabled(let disabled):
            if #available(iOS 16, macOS 13, tvOS 16, watchOS 9, visionOS 1, *) {
                return AnyView(v.scrollDisabled(disabled))
            }
            return v
        case .scrollIndicators(let vis, let axes):
            if #available(iOS 16, macOS 13, tvOS 16, watchOS 9, visionOS 1, *) {
                return AnyView(v.scrollIndicators(scrollIndicatorVisibility(vis), axes: axisSet(axes)))
            }
            return v
        case .scrollTargetBehavior(let behavior):
            #if os(iOS) || os(macOS) || os(tvOS) || os(visionOS)
            if #available(iOS 17, macOS 14, tvOS 17, visionOS 1, *) {
                switch behavior {
                case "paging": return AnyView(v.scrollTargetBehavior(.paging))
                default: return AnyView(v.scrollTargetBehavior(.viewAligned))
                }
            }
            return v
            #else
            _ = behavior; return v
            #endif
        case .scrollTargetLayout(let enabled):
            if #available(iOS 17, macOS 14, tvOS 17, watchOS 10, visionOS 1, *) {
                return AnyView(v.scrollTargetLayout(isEnabled: enabled))
            }
            return v
        case .scrollBounceBehavior(let behavior, let axes):
            #if os(iOS) || os(macOS) || os(tvOS) || os(visionOS) || os(watchOS)
            if #available(iOS 16.4, macOS 13.3, tvOS 16.4, watchOS 9.4, visionOS 1, *) {
                let b: ScrollBounceBehavior
                switch behavior {
                case "always": b = .always
                case "basedOnSize": b = .basedOnSize
                default: b = .automatic
                }
                return AnyView(v.scrollBounceBehavior(b, axes: axisSet(axes)))
            }
            return v
            #else
            _ = (behavior, axes); return v
            #endif
        case .contentMargins(let edges, let length, let placement):
            #if os(iOS) || os(macOS) || os(tvOS) || os(visionOS) || os(watchOS)
            if #available(iOS 17, macOS 14, tvOS 17, watchOS 10, visionOS 1, *) {
                let place: ContentMarginPlacement
                switch placement {
                case "scrollContent": place = .scrollContent
                case "scrollIndicators": place = .scrollIndicators
                default: place = .automatic
                }
                return AnyView(v.contentMargins(edgeSet(edges), CGFloat(length), for: place))
            }
            return v
            #else
            _ = (edges, length, placement); return v
            #endif
        case .safeAreaPadding(let edges, let length, let insets):
            if #available(iOS 17, macOS 14, tvOS 17, watchOS 10, visionOS 1, *) {
                if let insets {
                    return AnyView(v.safeAreaPadding(edgeInsets(insets)))
                }
                if let length {
                    return AnyView(v.safeAreaPadding(edgeSet(edges), CGFloat(length)))
                }
                return AnyView(v.safeAreaPadding(edgeSet(edges)))
            }
            // Pre-iOS-17 (etc.) fallback: `safeAreaPadding` is unavailable, carry the
            // intent as a no-op. WITHOUT this return the case falls through with no
            // value on the unavailable branch — a "missing return" that the macOS
            // build hides (deployment is macOS 14 → the `#available` is always-true)
            // but the iOS-simulator build (deployment < iOS 17) flags. Mirrors the
            // `.contentMargins` case above.
            return v
        // MARK: Control config — additional built-in styles (styles-views wave)
        case .textFieldStyle(let s):
            return applyTextFieldStyle(s, to: v)
        case .datePickerStyle(let s):
            return applyDatePickerStyle(s, to: v)
        case .controlGroupStyle(let s):
            return applyControlGroupStyle(s, to: v)
        case .groupBoxStyle, .disclosureGroupStyle, .tableStyle:
            // `.groupBoxStyle(.automatic)`/`.disclosureGroupStyle(.automatic)` have no
            // non-default built-in named static on iOS; `Table` (and `.tableStyle`)
            // is unavailable on iOS. Carry the intent but degrade to a no-op rather
            // than risk an unavailable static — the named-style data still rides.
            return v

        // MARK: Visibility / chrome / declarative effects (modifier-coverage sweep v6)
        case .hidden:
            return AnyView(v.hidden())
        case .labelsHidden:
            return AnyView(v.labelsHidden())
        case .labelsVisibility(let s):
            #if os(iOS) || os(macOS) || os(tvOS) || os(watchOS) || os(visionOS)
            if #available(iOS 18, macOS 15, tvOS 18, watchOS 11, visionOS 2, *) {
                return AnyView(v.labelsVisibility(titleVisibility(s)))
            }
            return v
            #else
            _ = s; return v
            #endif
        case .menuIndicator(let s):
            if #available(iOS 16, macOS 13, tvOS 17, watchOS 9, visionOS 1, *) {
                return AnyView(v.menuIndicator(titleVisibility(s)))
            }
            return v
        case .menuOrder(let s):
            #if os(iOS) || os(macOS) || os(tvOS) || os(watchOS) || os(visionOS)
            if #available(iOS 16, macOS 13, tvOS 16, watchOS 9, visionOS 1, *) {
                let order: MenuOrder
                switch s {
                case "fixed": order = .fixed
                #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
                case "priority": order = .priority
                #endif
                default: order = .automatic
                }
                return AnyView(v.menuOrder(order))
            }
            return v
            #else
            _ = s; return v
            #endif
        case .persistentSystemOverlays(let s):
            if #available(iOS 16, macOS 13, tvOS 16, watchOS 9, visionOS 1, *) {
                return AnyView(v.persistentSystemOverlays(titleVisibility(s)))
            }
            return v
        case .headerProminence(let s):
            return AnyView(v.headerProminence(s == "increased" ? .increased : .standard))
        case .badgeProminence(let s):
            #if os(iOS) || os(macOS) || os(visionOS)
            if #available(iOS 17, macOS 14, visionOS 1, *) {
                let p: BadgeProminence
                switch s {
                case "increased": p = .increased
                case "decreased": p = .decreased
                default: p = .standard
                }
                return AnyView(v.badgeProminence(p))
            }
            return v
            #else
            _ = s; return v
            #endif
        case .listItemTint(let c):
            if let c {
                return AnyView(v.listItemTint(color(c)))
            }
            return v
        case .listRowSeparatorTint(let c, let edges):
            return AnyView(v.listRowSeparatorTint(c.map { color($0) }, edges: verticalEdgeSet(edges)))
        case .listSectionSeparatorTint(let c, let edges):
            return AnyView(v.listSectionSeparatorTint(c.map { color($0) }, edges: verticalEdgeSet(edges)))
        case .containerShape(let k):
            // `.containerShape(_:)` requires an `InsettableShape` (AnyShape is not one),
            // so apply the concrete insettable shape per kind. UnevenRoundedRectangle /
            // ContainerRelativeShape degrade to the nearest insettable form.
            switch k {
            case .rectangle:
                return AnyView(v.containerShape(Rectangle()))
            case .roundedRectangle(let r):
                return AnyView(v.containerShape(RoundedRectangle(cornerRadius: CGFloat(r))))
            case .circle:
                return AnyView(v.containerShape(Circle()))
            case .ellipse:
                return AnyView(v.containerShape(Ellipse()))
            case .capsule:
                return AnyView(v.containerShape(Capsule()))
            case .containerRelative:
                return AnyView(v.containerShape(ContainerRelativeShape()))
            case .unevenRoundedRectangle(let tl, let tr, let bl, let br, _):
                let maxR = Swift.max(tl, tr, bl, br)
                return AnyView(v.containerShape(RoundedRectangle(cornerRadius: CGFloat(maxR))))
            }
        case .compositingGroup:
            return AnyView(v.compositingGroup())
        case .geometryGroup:
            if #available(iOS 17, macOS 14, tvOS 17, watchOS 10, visionOS 1, *) {
                return AnyView(v.geometryGroup())
            }
            return v
        case .drawingGroup(let opaque):
            return AnyView(v.drawingGroup(opaque: opaque))
        case .colorMultiply(let c):
            return AnyView(v.colorMultiply(color(c)))
        case .luminanceToAlpha:
            return AnyView(v.luminanceToAlpha())
        case .contentTransition(let s):
            if #available(iOS 16, macOS 13, tvOS 16, watchOS 9, visionOS 1, *) {
                let t: ContentTransition
                switch s {
                case "opacity": t = .opacity
                case "interpolate": t = .interpolate
                case "numericText": t = .numericText()
                default: t = .identity
                }
                return AnyView(v.contentTransition(t))
            }
            return v
        case .textSelection(let enabled):
            // `.enabled`/`.disabled` are DISTINCT types, so a ternary won't type-check.
            return enabled ? AnyView(v.textSelection(.enabled)) : AnyView(v.textSelection(.disabled))
        case .allowsTightening(let b):
            return AnyView(v.allowsTightening(b))
        case .flipsForRightToLeftLayoutDirection(let b):
            return AnyView(v.flipsForRightToLeftLayoutDirection(b))
        case .invalidatableContent(let b):
            if #available(iOS 17, macOS 14, tvOS 17, watchOS 10, visionOS 1, *) {
                return b ? AnyView(v.invalidatableContent()) : v
            }
            return v
        case .lineLimitReservesSpace(let limit, let reserves):
            if #available(iOS 16, macOS 13, tvOS 16, watchOS 9, visionOS 1, *) {
                return AnyView(v.lineLimit(limit, reservesSpace: reserves))
            }
            return AnyView(v.lineLimit(limit))
        case .defaultScrollAnchor(let p):
            #if os(iOS) || os(macOS) || os(tvOS) || os(watchOS) || os(visionOS)
            if #available(iOS 17, macOS 14, tvOS 17, watchOS 10, visionOS 1, *) {
                return AnyView(v.defaultScrollAnchor(unitPoint(p) ?? .center))
            }
            return v
            #else
            _ = p; return v
            #endif
        case .selectionDisabled(let b):
            if #available(iOS 17, macOS 14, tvOS 17, watchOS 10, visionOS 1, *) {
                return AnyView(v.selectionDisabled(b))
            }
            return v
        case .moveDisabled(let b):
            return AnyView(v.moveDisabled(b))
        case .deleteDisabled(let b):
            return AnyView(v.deleteDisabled(b))

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
        case .hostToken(let id):
            // A design-system color token: the value comes from the app's compiled-in
            // token via the thunk's `__patchTokens()`. Fall back to `.primary` if the
            // host supplied none for this id (PatchedBodyHost normally demotes the whole
            // view in that case, so this is belt-and-suspenders, never a wrong brand color).
            return context.tokens.color(for: id) ?? .primary
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
        shapeValue(k)
    }

    /// A concrete, type-erased `Shape` for `.clipShape` (which needs a `Shape`, not
    /// the `some View` the `shape(_:)` Group returns). `AnyShape` is iOS 16+ /
    /// macOS 13+ / tvOS 16+ / visionOS 1+ — the SDK's entire declared platform
    /// floor (see sdk/Package.swift), so it's always available here.
    func shapeValue(_ k: ShapeKind) -> AnyShape {
        switch k {
        case .rectangle: return AnyShape(Rectangle())
        case .roundedRectangle(let r): return AnyShape(RoundedRectangle(cornerRadius: CGFloat(r)))
        case .circle: return AnyShape(Circle())
        case .ellipse: return AnyShape(Ellipse())
        case .capsule: return AnyShape(Capsule())
        case .containerRelative:
            return AnyShape(ContainerRelativeShape())
        case .unevenRoundedRectangle(let tl, let tr, let bl, let br, let style):
            // `UnevenRoundedRectangle` is iOS 16.4+/macOS 13.3+/tvOS 16.4+/watchOS 9.4+.
            // Degrade to a RoundedRectangle of the max corner radius where it's not
            // available.
            #if os(iOS) || os(macOS) || os(tvOS) || os(watchOS) || os(visionOS)
            if #available(iOS 16.4, macOS 13.3, tvOS 16.4, watchOS 9.4, *) {
                return AnyShape(UnevenRoundedRectangle(
                    topLeadingRadius: CGFloat(tl), bottomLeadingRadius: CGFloat(bl),
                    bottomTrailingRadius: CGFloat(br), topTrailingRadius: CGFloat(tr),
                    style: roundedCornerStyle(style)))
            }
            #endif
            let maxR = Swift.max(tl, tr, bl, br)
            return AnyShape(RoundedRectangle(cornerRadius: CGFloat(maxR),
                                             style: roundedCornerStyle(style)))
        }
    }

    private func roundedCornerStyle(_ s: IRRoundedCornerStyle) -> RoundedCornerStyle {
        switch s {
        case .circular: return .circular
        case .continuous: return .continuous
        }
    }

    /// Build a real `Text` honoring the styledText content flags. `markdown` does a
    /// best-effort `AttributedString(markdown:)`; `localized` resolves the shipped
    /// `.strings` via `LocalizedStringKey`; `verbatim` skips localization.
    func styledText(_ s: String, verbatim: Bool, markdown: Bool, localized: Bool) -> Text {
        if markdown {
            if let attr = try? AttributedString(markdown: s) {
                return Text(attr)
            }
            return Text(verbatim: s)
        }
        if localized {
            return Text(LocalizedStringKey(s))
        }
        if verbatim {
            return Text(verbatim: s)
        }
        return Text(s)
    }

    /// Replay an `[IRPathCommand]` into a real `Path` (a `Shape`).
    func buildPath(_ commands: [IRPathCommand]) -> Path {
        var p = Path()
        for c in commands {
            switch c {
            case .move(let x, let y):
                p.move(to: CGPoint(x: x, y: y))
            case .line(let x, let y):
                p.addLine(to: CGPoint(x: x, y: y))
            case .quad(let cpx, let cpy, let x, let y):
                p.addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: cpx, y: cpy))
            case .curve(let cp1x, let cp1y, let cp2x, let cp2y, let x, let y):
                p.addCurve(to: CGPoint(x: x, y: y),
                           control1: CGPoint(x: cp1x, y: cp1y),
                           control2: CGPoint(x: cp2x, y: cp2y))
            case .closeSubpath:
                p.closeSubpath()
            case .addRect(let x, let y, let width, let height):
                p.addRect(CGRect(x: x, y: y, width: width, height: height))
            case .addRoundedRect(let x, let y, let width, let height, let cornerRadius):
                p.addRoundedRect(in: CGRect(x: x, y: y, width: width, height: height),
                                 cornerSize: CGSize(width: cornerRadius, height: cornerRadius))
            }
        }
        return p
    }

    /// Map `[IRGridItem]` to SwiftUI `[GridItem]` (the column/row tracks).
    func gridItems(_ items: [IRGridItem]) -> [GridItem] {
        items.map { item in
            let size: GridItem.Size
            switch item.size {
            case .fixed(let x):
                size = .fixed(CGFloat(x))
            case .flexible(let min, let max):
                size = .flexible(minimum: CGFloat(min), maximum: cg(max) ?? .infinity)
            case .adaptive(let min, let max):
                size = .adaptive(minimum: CGFloat(min), maximum: cg(max) ?? .infinity)
            }
            return GridItem(size, spacing: item.spacing.map { CGFloat($0) },
                            alignment: item.alignment.map { zalignment($0) })
        }
    }

    /// Build a real (UNBOUND) `TabView` from `[IRTab]` + the style flag. SwiftUI owns
    /// the selected tab. `.tabItem` + `.tag` are applied per tab.
    @ViewBuilder
    func tabView(tabs: [IRTab], style: IRTabViewStyle) -> some View {
        let tv = TabView {
            ForEach(Array(tabs.enumerated()), id: \.offset) { _, tab in
                self.renderChildren(tab.content)
                    .tabItem { self.renderChildren(tab.tabItem) }
                    .tag(tab.tag)
            }
        }
        switch style {
        case .automatic:
            tv
        case .page:
            // `PageTabViewStyle` is iOS 14+/watchOS 7+ but unavailable on macOS/tvOS —
            // fall back to the automatic style there.
            #if os(iOS) || os(watchOS) || os(visionOS)
            tv.tabViewStyle(.page)
            #else
            tv
            #endif
        }
    }

    /// Map an `IRLength?` flexible-frame bound to SwiftUI's `CGFloat?`:
    /// `.points(x)` → `CGFloat(x)`, `.infinity` → `.infinity`, nil → nil.
    func cg(_ l: IRLength?) -> CGFloat? {
        switch l {
        case .none: return nil
        case .points(let x): return CGFloat(x)
        case .infinity: return .infinity
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

    // MARK: - Unified style vocabulary → real SwiftUI

    /// Resolve an `IRShapeStyle` to a real `AnyShapeStyle` (iOS 16+ / the SDK's
    /// entire declared platform floor — same as `AnyShape`, see `shapeValue`).
    func renderShapeStyle(_ s: IRShapeStyle) -> AnyShapeStyle {
        switch s {
        case .color(let c):
            return AnyShapeStyle(color(c))
        case .linearGradient(let g, let sp, let ep):
            return AnyShapeStyle(LinearGradient(gradient: gradient(g),
                                                startPoint: unitPointValue(sp), endPoint: unitPointValue(ep)))
        case .radialGradient(let g, let c, let sr, let er):
            return AnyShapeStyle(RadialGradient(gradient: gradient(g), center: unitPointValue(c),
                                                startRadius: CGFloat(sr), endRadius: CGFloat(er)))
        case .angularGradient(let g, let c, let sa, let ea):
            return AnyShapeStyle(AngularGradient(gradient: gradient(g), center: unitPointValue(c),
                                                 startAngle: .degrees(sa), endAngle: .degrees(ea)))
        case .material(let m):
            return AnyShapeStyle(material(m))
        case .hierarchical(let level):
            switch level {
            case 0: return AnyShapeStyle(.primary)
            case 1: return AnyShapeStyle(.secondary)
            case 2: return AnyShapeStyle(.tertiary)
            case 3: return AnyShapeStyle(.quaternary)
            default:
                if #available(iOS 16, macOS 13, tvOS 16, watchOS 9, visionOS 1, *) {
                    return AnyShapeStyle(.quinary)
                }
                return AnyShapeStyle(.quaternary)
            }
        case .semantic(let name):
            // `.separator`/`.placeholder`/`.link` ShapeStyles are iOS 17 / macOS 14+
            // ONLY — the SDK floor is iOS 16, so they MUST be availability-guarded (an
            // unguarded reference fails to compile ANY iOS-16-floored app linking the
            // SDK). Pre-17 they degrade to the nearest always-available hierarchical style.
            switch name {
            case "tint": return AnyShapeStyle(.tint)
            case "foreground": return AnyShapeStyle(.foreground)
            case "separator":
                if #available(iOS 17, macOS 14, tvOS 17, watchOS 10, visionOS 1, *) {
                    return AnyShapeStyle(.separator)
                }
                return AnyShapeStyle(.secondary)
            case "placeholder":
                if #available(iOS 17, macOS 14, tvOS 17, watchOS 10, visionOS 1, *) {
                    return AnyShapeStyle(.placeholder)
                }
                return AnyShapeStyle(.tertiary)
            case "link":
                if #available(iOS 17, macOS 14, tvOS 17, watchOS 10, visionOS 1, *) {
                    return AnyShapeStyle(.link)
                }
                return AnyShapeStyle(.tint)
            default: return AnyShapeStyle(.foreground)
            }
        case .shadow(let style):
            if #available(iOS 16, macOS 13, tvOS 16, watchOS 9, visionOS 1, *) {
                let drop: ShadowStyle = .drop(color: style.color.map { color($0) } ?? Color.black.opacity(0.33),
                                              radius: CGFloat(style.radius),
                                              x: CGFloat(style.x), y: CGFloat(style.y))
                return AnyShapeStyle(.foreground.shadow(drop))
            }
            return AnyShapeStyle(.foreground)
        }
    }

    private func gradient(_ g: IRGradient) -> Gradient {
        Gradient(stops: g.stops.map { Gradient.Stop(color: color($0.color), location: CGFloat($0.location)) })
    }

    func material(_ m: IRMaterial) -> Material {
        switch m {
        case .ultraThin: return .ultraThinMaterial
        case .thin: return .thinMaterial
        case .regular: return .regularMaterial
        case .thick: return .thickMaterial
        case .bar: return .bar
        }
    }

    /// `.foregroundStyle(_:)` with 1–3 layers. SwiftUI's 2-/3-layer overload needs
    /// the secondary/tertiary styles; we apply the available overload by count.
    private func applyForegroundStyle(_ layers: [IRShapeStyle], to v: AnyView) -> AnyView {
        let styles = layers.map { renderShapeStyle($0) }
        guard let p = styles.first else { return v }
        if #available(iOS 17, macOS 14, tvOS 17, watchOS 10, visionOS 1, *) {
            switch styles.count {
            case 1: return AnyView(v.foregroundStyle(p))
            case 2: return AnyView(v.foregroundStyle(p, styles[1]))
            default: return AnyView(v.foregroundStyle(p, styles[1], styles[2]))
            }
        }
        // Pre-17: only the single-layer overload is broadly available.
        return AnyView(v.foregroundStyle(p))
    }

    func unitPoint(_ p: IRUnitPoint?) -> UnitPoint? {
        guard let p else { return nil }
        return unitPointValue(p)
    }
    func unitPointValue(_ p: IRUnitPoint) -> UnitPoint {
        switch p {
        case .center: return .center
        case .top: return .top
        case .bottom: return .bottom
        case .leading: return .leading
        case .trailing: return .trailing
        case .topLeading: return .topLeading
        case .topTrailing: return .topTrailing
        case .bottomLeading: return .bottomLeading
        case .bottomTrailing: return .bottomTrailing
        case .xy(let x, let y): return UnitPoint(x: CGFloat(x), y: CGFloat(y))
        }
    }

    func contentMode(_ m: IRContentMode) -> ContentMode {
        m == .fill ? .fill : .fit
    }

    func strokeStyle(_ s: IRStrokeStyle) -> StrokeStyle {
        StrokeStyle(lineWidth: CGFloat(s.lineWidth),
                    lineCap: lineCap(s.cap), lineJoin: lineJoin(s.join),
                    miterLimit: CGFloat(s.miterLimit),
                    dash: s.dash.map { CGFloat($0) }, dashPhase: CGFloat(s.dashPhase))
    }
    private func lineCap(_ c: String) -> CGLineCap {
        switch c { case "round": return .round; case "square": return .square; default: return .butt }
    }
    private func lineJoin(_ j: String) -> CGLineJoin {
        switch j { case "round": return .round; case "bevel": return .bevel; default: return .miter }
    }

    func blendMode(_ m: IRBlendMode) -> BlendMode {
        switch m {
        case .normal: return .normal
        case .multiply: return .multiply
        case .screen: return .screen
        case .overlay: return .overlay
        case .darken: return .darken
        case .lighten: return .lighten
        case .colorDodge: return .colorDodge
        case .colorBurn: return .colorBurn
        case .softLight: return .softLight
        case .hardLight: return .hardLight
        case .difference: return .difference
        case .exclusion: return .exclusion
        case .hue: return .hue
        case .saturation: return .saturation
        case .color: return .color
        case .luminosity: return .luminosity
        case .sourceAtop: return .sourceAtop
        case .destinationOver: return .destinationOver
        case .destinationOut: return .destinationOut
        case .plusDarker: return .plusDarker
        case .plusLighter: return .plusLighter
        }
    }

    func textCase(_ c: String?) -> Text.Case? {
        switch c {
        case "uppercase": return .uppercase
        case "lowercase": return .lowercase
        default: return nil
        }
    }

    func truncationMode(_ m: String) -> Text.TruncationMode {
        switch m {
        case "head": return .head
        case "middle": return .middle
        default: return .tail
        }
    }

    func redactionReason(_ r: String) -> RedactionReasons {
        switch r {
        case "privacy": return .privacy
        case "invalidated":
            if #available(iOS 17, macOS 14, tvOS 17, watchOS 10, visionOS 1, *) { return .invalidated }
            return .placeholder
        default: return .placeholder
        }
    }

    func symbolRenderingMode(_ m: String) -> SymbolRenderingMode {
        switch m {
        case "hierarchical": return .hierarchical
        case "palette": return .palette
        case "multicolor": return .multicolor
        default: return .monochrome
        }
    }

    func symbolVariant(_ v: String) -> SymbolVariants {
        switch v {
        case "circle": return .circle
        case "square": return .square
        case "rectangle": return .rectangle
        case "fill": return .fill
        case "slash": return .slash
        default: return SymbolVariants.none
        }
    }

    func imageScale(_ s: String) -> Image.Scale {
        switch s {
        case "small": return .small
        case "large": return .large
        default: return .medium
        }
    }

    func dynamicTypeSize(_ s: String) -> DynamicTypeSize {
        switch s {
        case "xSmall": return .xSmall
        case "small": return .small
        case "medium": return .medium
        case "large": return .large
        case "xLarge": return .xLarge
        case "xxLarge": return .xxLarge
        case "xxxLarge": return .xxxLarge
        case "accessibility1": return .accessibility1
        case "accessibility2": return .accessibility2
        case "accessibility3": return .accessibility3
        case "accessibility4": return .accessibility4
        case "accessibility5": return .accessibility5
        default: return .large
        }
    }

    func colorScheme(_ s: String?) -> ColorScheme? {
        switch s {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    func safeAreaRegions(_ r: String) -> SafeAreaRegions {
        switch r {
        case "container": return .container
        case "keyboard": return .keyboard
        default: return .all
        }
    }

    func edgeSet(_ e: String) -> Edge.Set {
        var set: Edge.Set = []
        for token in e.split(separator: "+") {
            switch token {
            case "all": return .all
            case "top": set.insert(.top)
            case "bottom": set.insert(.bottom)
            case "leading": set.insert(.leading)
            case "trailing": set.insert(.trailing)
            case "horizontal": set.insert(.horizontal)
            case "vertical": set.insert(.vertical)
            default: break
            }
        }
        return set.isEmpty ? .all : set
    }

    /// `.listRowSeparator`/`.listSectionSeparator` take a `VerticalEdge.Set` (only
    /// top/bottom). Map our edge string, ignoring horizontal edges (no analogue).
    func verticalEdgeSet(_ e: String) -> VerticalEdge.Set {
        var set: VerticalEdge.Set = []
        for token in e.split(separator: "+") {
            switch token {
            case "all", "vertical": return .all
            case "top": set.insert(.top)
            case "bottom": set.insert(.bottom)
            default: break
            }
        }
        return set.isEmpty ? .all : set
    }

    func axisSet(_ a: String) -> Axis.Set {
        var set: Axis.Set = []
        for token in a.split(separator: "+") {
            switch token {
            case "all": return [.horizontal, .vertical]
            case "horizontal": set.insert(.horizontal)
            case "vertical": set.insert(.vertical)
            default: break
            }
        }
        return set.isEmpty ? .vertical : set
    }

    func transition(_ t: IRTransition) -> AnyTransition {
        switch t {
        case .identity: return .identity
        case .opacity: return .opacity
        case .scale(let s, let a):
            return s == 0 ? .scale : .scale(scale: CGFloat(s), anchor: unitPointValue(a))
        case .slide: return .slide
        case .move(let e): return .move(edge: edge(e))
        case .push(let e):
            if #available(iOS 16, macOS 13, tvOS 16, watchOS 9, visionOS 1, *) {
                return .push(from: edge(e))
            }
            return .move(edge: edge(e))
        case .offset(let x, let y): return .offset(x: CGFloat(x), y: CGFloat(y))
        case .blurReplace:
            // `.blurReplace` (iOS 17+) isn't surfaced as a static on every SDK we
            // build against; degrade to the always-available opacity transition.
            return .opacity
        case .combined(let ts):
            return ts.reduce(AnyTransition.identity) { $0.combined(with: transition($1)) }
        case .asymmetric(let i, let r):
            return .asymmetric(insertion: transition(i), removal: transition(r))
        }
    }
    private func edge(_ e: String) -> Edge {
        switch e {
        case "top": return .top
        case "bottom": return .bottom
        case "leading": return .leading
        case "trailing": return .trailing
        default: return .top
        }
    }

    // MARK: - Content-bearing layout modifiers

    private func applySafeAreaInset(edge: String, alignment: IRAlignment?, spacing: Double?,
                                    content: [ViewNode], to v: AnyView) -> AnyView {
        #if os(watchOS)
        return v
        #else
        if #available(iOS 15, macOS 12, tvOS 15, visionOS 1, *) {
            if edge == "top" || edge == "bottom" {
                let e: VerticalEdge = (edge == "top") ? .top : .bottom
                return AnyView(v.safeAreaInset(edge: e, alignment: hAlign(alignment),
                                               spacing: spacing.map { CGFloat($0) }) { renderChildren(content) })
            }
            #if os(iOS) || os(visionOS) || os(macOS)
            if #available(iOS 17, macOS 14, visionOS 1, *) {
                let e: HorizontalEdge = (edge == "leading") ? .leading : .trailing
                return AnyView(v.safeAreaInset(edge: e, alignment: vAlign(alignment),
                                               spacing: spacing.map { CGFloat($0) }) { renderChildren(content) })
            }
            #endif
            return v
        }
        return v
        #endif
    }
    private func hAlign(_ a: IRAlignment?) -> HorizontalAlignment {
        switch a {
        case .leading, .topLeading, .bottomLeading: return .leading
        case .trailing, .topTrailing, .bottomTrailing: return .trailing
        default: return .center
        }
    }
    private func vAlign(_ a: IRAlignment?) -> VerticalAlignment {
        switch a {
        case .top, .topLeading, .topTrailing: return .top
        case .bottom, .bottomLeading, .bottomTrailing: return .bottom
        default: return .center
        }
    }

    // MARK: - Gestures

    private func applyDragGesture(minDistance: Double, onChanged: EventID?, onEnded: EventID?,
                                  to v: AnyView) -> AnyView {
        #if os(tvOS)
        return v
        #else
        var g = DragGesture(minimumDistance: CGFloat(minDistance))
            .onChanged { [d = context.dispatcher] val in
                if let onChanged { d?.send(onChanged, .point(Double(val.translation.width), Double(val.translation.height))) }
            }
            .onEnded { [d = context.dispatcher] val in
                if let onEnded { d?.send(onEnded, .point(Double(val.translation.width), Double(val.translation.height))) }
            }
        _ = g
        return AnyView(v.gesture(g))
        #endif
    }

    // MARK: - Control-config built-in styles

    private func applyButtonStyle(_ s: IRButtonStyle, to v: AnyView) -> AnyView {
        switch s {
        case .bordered:
            if #available(iOS 15, macOS 12, tvOS 17, watchOS 8, visionOS 1, *) { return AnyView(v.buttonStyle(.bordered)) }
            return AnyView(v.buttonStyle(.automatic))
        case .borderedProminent:
            if #available(iOS 15, macOS 12, tvOS 17, watchOS 8, visionOS 1, *) { return AnyView(v.buttonStyle(.borderedProminent)) }
            return AnyView(v.buttonStyle(.automatic))
        case .borderless:
            return AnyView(v.buttonStyle(.borderless))
        case .plain:
            return AnyView(v.buttonStyle(.plain))
        case .automatic:
            return AnyView(v.buttonStyle(.automatic))
        }
    }

    // MARK: Additional built-in styles (styles-views wave)

    private func applyTextFieldStyle(_ s: String, to v: AnyView) -> AnyView {
        // `.textFieldStyle(_:)` — `.roundedBorder`/`.plain`/`.automatic`. The
        // rounded-border style is iOS/macOS/visionOS-only (not tvOS/watchOS).
        switch s {
        case "roundedBorder":
            #if os(iOS) || os(macOS) || os(visionOS)
            return AnyView(v.textFieldStyle(.roundedBorder))
            #else
            return AnyView(v.textFieldStyle(.automatic))
            #endif
        case "plain":
            return AnyView(v.textFieldStyle(.plain))
        default:
            return AnyView(v.textFieldStyle(.automatic))
        }
    }

    private func applyDatePickerStyle(_ s: String, to v: AnyView) -> AnyView {
        // `.datePickerStyle(_:)` — DatePicker itself is unavailable on tvOS/watchOS,
        // so the styles are iOS/macOS/visionOS-only; degrade to the input view there.
        #if os(iOS) || os(macOS) || os(visionOS)
        switch s {
        case "compact":
            if #available(iOS 14, macOS 10.15.4, *) { return AnyView(v.datePickerStyle(.compact)) }
            return AnyView(v.datePickerStyle(.automatic))
        case "graphical":
            if #available(iOS 14, macOS 10.15.4, *) { return AnyView(v.datePickerStyle(.graphical)) }
            return AnyView(v.datePickerStyle(.automatic))
        case "wheel":
            #if os(iOS) || os(visionOS)
            return AnyView(v.datePickerStyle(.wheel))
            #else
            return AnyView(v.datePickerStyle(.automatic))
            #endif
        default:
            return AnyView(v.datePickerStyle(.automatic))
        }
        #else
        _ = s
        return v
        #endif
    }

    private func applyControlGroupStyle(_ s: String, to v: AnyView) -> AnyView {
        // `.controlGroupStyle(_:)` — `.navigation`/`.compactMenu`/`.menu`/`.palette`/
        // `.automatic`. Each named static is version-gated + niche; the most portable
        // is `.navigation` (iOS 16+). Anything unavailable degrades to `.automatic`.
        #if os(iOS) || os(macOS) || os(visionOS)
        switch s {
        case "navigation":
            if #available(iOS 16, macOS 13, *) { return AnyView(v.controlGroupStyle(.navigation)) }
            return AnyView(v.controlGroupStyle(.automatic))
        case "menu":
            if #available(iOS 16.4, macOS 13.3, *) { return AnyView(v.controlGroupStyle(.menu)) }
            return AnyView(v.controlGroupStyle(.automatic))
        case "compactMenu":
            if #available(iOS 16.4, macOS 13.3, *) { return AnyView(v.controlGroupStyle(.compactMenu)) }
            return AnyView(v.controlGroupStyle(.automatic))
        case "palette":
            if #available(iOS 17, macOS 14, *) { return AnyView(v.controlGroupStyle(.palette)) }
            return AnyView(v.controlGroupStyle(.automatic))
        default:
            return AnyView(v.controlGroupStyle(.automatic))
        }
        #else
        _ = s
        return v
        #endif
    }

    private func applyListStyle(_ s: IRListStyle, to v: AnyView) -> AnyView {
        #if os(watchOS)
        return AnyView(v.listStyle(.automatic))
        #else
        switch s {
        case .plain: return AnyView(v.listStyle(.plain))
        case .grouped:
            #if os(iOS) || os(tvOS) || os(visionOS)
            return AnyView(v.listStyle(.grouped))
            #else
            return AnyView(v.listStyle(.automatic))
            #endif
        case .insetGrouped:
            #if os(iOS) || os(visionOS)
            return AnyView(v.listStyle(.insetGrouped))
            #else
            return AnyView(v.listStyle(.automatic))
            #endif
        case .inset:
            #if os(iOS) || os(macOS) || os(visionOS)
            return AnyView(v.listStyle(.inset))
            #else
            return AnyView(v.listStyle(.automatic))
            #endif
        case .sidebar:
            #if os(iOS) || os(macOS) || os(visionOS)
            return AnyView(v.listStyle(.sidebar))
            #else
            return AnyView(v.listStyle(.automatic))
            #endif
        case .bordered:
            #if os(macOS)
            return AnyView(v.listStyle(.bordered))
            #else
            return AnyView(v.listStyle(.automatic))
            #endif
        case .automatic:
            return AnyView(v.listStyle(.automatic))
        }
        #endif
    }

    private func applyPickerStyle(_ s: String, to v: AnyView) -> AnyView {
        switch s {
        case "segmented":
            #if os(iOS) || os(macOS) || os(tvOS) || os(visionOS)
            return AnyView(v.pickerStyle(.segmented))
            #else
            return AnyView(v.pickerStyle(.automatic))
            #endif
        case "menu":
            if #available(iOS 16, macOS 13, tvOS 17, watchOS 9, visionOS 1, *) {
                return AnyView(v.pickerStyle(.menu))
            }
            return AnyView(v.pickerStyle(.automatic))
        case "inline":
            if #available(iOS 16, macOS 13, tvOS 16, watchOS 9, visionOS 1, *) {
                return AnyView(v.pickerStyle(.inline))
            }
            return AnyView(v.pickerStyle(.automatic))
        case "wheel":
            #if os(iOS) || os(watchOS) || os(visionOS)
            return AnyView(v.pickerStyle(.wheel))
            #else
            return AnyView(v.pickerStyle(.automatic))
            #endif
        case "navigationLink":
            #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
            if #available(iOS 16, tvOS 16, watchOS 9, visionOS 1, *) {
                return AnyView(v.pickerStyle(.navigationLink))
            }
            return AnyView(v.pickerStyle(.automatic))
            #else
            return AnyView(v.pickerStyle(.automatic))
            #endif
        default:
            return AnyView(v.pickerStyle(.automatic))
        }
    }

    /// `.tabViewStyle(.page[indexDisplayMode:])`. `PageTabViewStyle` is iOS/watchOS/
    /// visionOS only (NOT macOS/tvOS) — degrade to `.automatic` elsewhere. The
    /// string carries the index-display mode ("page" = automatic, "page.always",
    /// "page.never").
    private func applyTabViewStyle(_ s: String, to v: AnyView) -> AnyView {
        #if os(iOS) || os(watchOS) || os(visionOS)
        switch s {
        case "page.always":
            return AnyView(v.tabViewStyle(.page(indexDisplayMode: .always)))
        case "page.never":
            return AnyView(v.tabViewStyle(.page(indexDisplayMode: .never)))
        case "page":
            return AnyView(v.tabViewStyle(.page))
        default:
            return AnyView(v.tabViewStyle(.automatic))
        }
        #else
        _ = s
        return AnyView(v.tabViewStyle(.automatic))
        #endif
    }

    /// `.indexViewStyle(.page[backgroundDisplayMode:])`. `PageIndexViewStyle` is
    /// iOS/visionOS only. The string's suffix is the background-display mode.
    private func applyIndexViewStyle(_ s: String, to v: AnyView) -> AnyView {
        #if os(iOS) || os(visionOS)
        switch s {
        case "page.always":
            return AnyView(v.indexViewStyle(.page(backgroundDisplayMode: .always)))
        case "page.never":
            return AnyView(v.indexViewStyle(.page(backgroundDisplayMode: .never)))
        default:
            return AnyView(v.indexViewStyle(.page(backgroundDisplayMode: .automatic)))
        }
        #else
        _ = s
        return v
        #endif
    }

    private func applyToggleStyle(_ s: String, to v: AnyView) -> AnyView {
        switch s {
        case "switch":
            #if os(iOS) || os(macOS) || os(watchOS) || os(visionOS)
            return AnyView(v.toggleStyle(.switch))
            #else
            return AnyView(v.toggleStyle(.automatic))
            #endif
        case "button":
            if #available(iOS 15, macOS 12, tvOS 17, watchOS 9, visionOS 1, *) {
                return AnyView(v.toggleStyle(.button))
            }
            return AnyView(v.toggleStyle(.automatic))
        default:
            return AnyView(v.toggleStyle(.automatic))
        }
    }

    private func applyLabelStyle(_ s: String, to v: AnyView) -> AnyView {
        switch s {
        case "iconOnly": return AnyView(v.labelStyle(.iconOnly))
        case "titleOnly": return AnyView(v.labelStyle(.titleOnly))
        case "titleAndIcon": return AnyView(v.labelStyle(.titleAndIcon))
        default: return AnyView(v.labelStyle(.automatic))
        }
    }

    private func applyProgressViewStyle(_ s: String, to v: AnyView) -> AnyView {
        switch s {
        case "linear": return AnyView(v.progressViewStyle(.linear))
        case "circular": return AnyView(v.progressViewStyle(.circular))
        default: return AnyView(v.progressViewStyle(.automatic))
        }
    }

    private func applyButtonBorderShape(_ s: String, to v: AnyView) -> AnyView {
        switch s {
        case "capsule": return AnyView(v.buttonBorderShape(.capsule))
        case "roundedRectangle": return AnyView(v.buttonBorderShape(.roundedRectangle))
        case "circle":
            if #available(iOS 17, macOS 14, tvOS 17, watchOS 10, visionOS 1, *) {
                return AnyView(v.buttonBorderShape(.circle))
            }
            return AnyView(v.buttonBorderShape(.automatic))
        default: return AnyView(v.buttonBorderShape(.automatic))
        }
    }

    private func applyControlSize(_ s: String, to v: AnyView) -> AnyView {
        #if os(tvOS)
        return v
        #else
        switch s {
        case "mini": return AnyView(v.controlSize(.mini))
        case "small": return AnyView(v.controlSize(.small))
        case "large": return AnyView(v.controlSize(.large))
        case "extraLarge":
            if #available(iOS 17, macOS 14, watchOS 10, visionOS 1, *) {
                return AnyView(v.controlSize(.extraLarge))
            }
            return AnyView(v.controlSize(.large))
        default: return AnyView(v.controlSize(.regular))
        }
        #endif
    }

    #if os(iOS) || os(tvOS) || os(visionOS)
    func keyboardType(_ s: String) -> UIKeyboardType {
        switch s {
        case "numberPad": return .numberPad
        case "decimalPad": return .decimalPad
        case "emailAddress": return .emailAddress
        case "phonePad": return .phonePad
        case "URL", "url": return .URL
        case "numbersAndPunctuation": return .numbersAndPunctuation
        case "namePhonePad": return .namePhonePad
        case "twitter": return .twitter
        case "webSearch": return .webSearch
        case "asciiCapable": return .asciiCapable
        default: return .default
        }
    }
    func textContentType(_ s: String) -> UITextContentType? {
        switch s {
        case "emailAddress": return .emailAddress
        case "password": return .password
        case "newPassword": return .newPassword
        case "username": return .username
        case "name": return .name
        case "givenName": return .givenName
        case "familyName": return .familyName
        case "telephoneNumber": return .telephoneNumber
        case "URL", "url": return .URL
        case "oneTimeCode": return .oneTimeCode
        case "fullStreetAddress": return .fullStreetAddress
        case "postalCode": return .postalCode
        default: return nil
        }
    }
    @available(iOS 15, tvOS 15, visionOS 1, *)
    func textAutocap(_ s: String) -> TextInputAutocapitalization {
        switch s {
        case "never": return .never
        case "words": return .words
        case "characters": return .characters
        default: return .sentences
        }
    }
    #endif

    @available(iOS 15, macOS 12, tvOS 15, watchOS 8, visionOS 1, *)
    func submitLabel(_ s: String) -> SubmitLabel {
        switch s {
        case "go": return .go
        case "send": return .send
        case "join": return .join
        case "route": return .route
        case "search": return .search
        case "return": return .return
        case "next": return .next
        case "continue": return .continue
        default: return .done
        }
    }

    // MARK: - Host-state helpers (B — presentation / selection / navigation)

    func buttonRole(_ r: IRButtonRole) -> ButtonRole {
        switch r {
        case .destructive: return .destructive
        case .cancel: return .cancel
        }
    }

    /// The proven presentation bridge: a `Binding<Bool>` whose GET returns the
    /// guest-emitted flag and whose SET (incl. a system-initiated swipe/back
    /// dismiss) dispatches `event` into the guest's `dispatch`. SwiftUI owns the
    /// presentation MACHINERY; the guest owns the flag value.
    func presentationBinding(_ value: Bool, _ event: EventID) -> Binding<Bool> {
        Binding<Bool>(
            get: { value },
            set: { [d = context.dispatcher] new in d?.send(event, .bool(new)) }
        )
    }

    func titleVisibility(_ s: String) -> Visibility {
        switch s {
        case "visible": return .visible
        case "hidden": return .hidden
        default: return .automatic
        }
    }

    // MARK: Scroll & layout (sweep — added at END)

    /// `.scrollIndicators(_:)` takes a `ScrollIndicatorVisibility` (iOS 16+). Map our
    /// string ("automatic"|"visible"|"hidden"|"never").
    @available(iOS 16, macOS 13, tvOS 16, watchOS 9, visionOS 1, *)
    func scrollIndicatorVisibility(_ s: String) -> ScrollIndicatorVisibility {
        switch s {
        case "visible": return .visible
        case "hidden": return .hidden
        case "never": return .never
        default: return .automatic
        }
    }

    /// Map trait names (joined with "+") → `AccessibilityTraits`. Unknown names drop.
    func accessibilityTraits(_ s: String) -> AccessibilityTraits {
        var traits = AccessibilityTraits()
        for token in s.split(separator: "+").map(String.init) {
            switch token {
            case "isButton": traits.insert(.isButton)
            case "isHeader": traits.insert(.isHeader)
            case "isSelected": traits.insert(.isSelected)
            case "isImage": traits.insert(.isImage)
            case "isLink": traits.insert(.isLink)
            case "isSearchField": traits.insert(.isSearchField)
            case "isStaticText":
                if #available(iOS 17, macOS 14, tvOS 17, watchOS 10, visionOS 1, *) {
                    traits.insert(.isStaticText)
                }
            case "isToggle":
                if #available(iOS 17, macOS 14, tvOS 17, watchOS 10, visionOS 1, *) {
                    traits.insert(.isToggle)
                }
            case "isModal": traits.insert(.isModal)
            case "isSummaryElement": traits.insert(.isSummaryElement)
            case "updatesFrequently": traits.insert(.updatesFrequently)
            case "playsSound": traits.insert(.playsSound)
            case "startsMediaSession": traits.insert(.startsMediaSession)
            case "allowsDirectInteraction": traits.insert(.allowsDirectInteraction)
            case "causesPageTurn": traits.insert(.causesPageTurn)
            default: break
            }
        }
        return traits
    }

    /// Map the detent strings ("medium"|"large"|"fraction:<n>"|"height:<n>") to a
    /// `Set<PresentationDetent>`. Unknown tokens are dropped (an empty set → no-op).
    @available(iOS 16, macOS 13, *)
    func presentationDetentSet(_ detents: [String]) -> Set<PresentationDetent> {
        var set: Set<PresentationDetent> = []
        for d in detents {
            switch d {
            case "medium": set.insert(.medium)
            case "large": set.insert(.large)
            default:
                if d.hasPrefix("fraction:"), let n = Double(d.dropFirst("fraction:".count)) {
                    set.insert(.fraction(CGFloat(n)))
                } else if d.hasPrefix("height:"), let n = Double(d.dropFirst("height:".count)) {
                    set.insert(.height(CGFloat(n)))
                }
            }
        }
        return set
    }

    /// `.environment(\.<key>, <value>)` for the reconstructable keys. An unknown key
    /// (shouldn't reach here — the emitter gates) is a faithful no-op.
    func applyEnvironmentValue(key: String, value: String, to v: AnyView) -> AnyView {
        switch key {
        case "layoutDirection":
            return AnyView(v.environment(\.layoutDirection,
                                         value == "rightToLeft" ? .rightToLeft : .leftToRight))
        case "colorScheme":
            return AnyView(v.environment(\.colorScheme, value == "dark" ? .dark : .light))
        case "locale":
            return AnyView(v.environment(\.locale, Locale(identifier: value)))
        default:
            return v
        }
    }

    /// `.navigationViewStyle(_:)` — "stack" → StackNavigationViewStyle (the only
    /// broadly-supported named style worth reconstituting; columns/automatic →
    /// automatic). Available on iOS/tvOS/watchOS; a no-op elsewhere.
    func applyNavigationViewStyle(_ s: String, to v: AnyView) -> AnyView {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        switch s {
        case "stack": return AnyView(v.navigationViewStyle(.stack))
        default: return AnyView(v.navigationViewStyle(.automatic))
        }
        #else
        _ = s; return v
        #endif
    }

    #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
    func titleDisplayMode(_ s: String) -> NavigationBarItem.TitleDisplayMode {
        // The type `navigationBarTitleDisplayMode(_:)` takes is
        // `NavigationBarItem.TitleDisplayMode` (iOS 14+) — NOT the iOS-17-only
        // `ToolbarTitleDisplayMode`. Map the three named modes.
        switch s {
        case "inline": return .inline
        case "large": return .large
        default: return .automatic
        }
    }
    #endif

    /// Build a real bound `Picker`. The selection `Binding` GET returns the guest's
    /// current tag; SET dispatches the chosen option's tag value. `kind` decides
    /// whether the `Binding`/tags are Int or String (a `Picker` is generic over its
    /// SelectionValue, so the projection must be concrete).
    @ViewBuilder
    func picker(label: [ViewNode], selection: IRValue, kind: IRSelectionKind,
                options: [IRPickerOption], event: EventID) -> some View {
        switch kind {
        case .int:
            let current = Self.intValue(selection) ?? 0
            let binding = Binding<Int>(
                get: { current },
                set: { [d = context.dispatcher] new in d?.send(event, .int(new)) }
            )
            Picker(selection: binding) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, opt in
                    self.renderChildren(opt.label).tag(Self.intValue(opt.tag) ?? 0)
                }
            } label: {
                renderChildren(label)
            }
        case .string:
            let current = Self.stringValue(selection) ?? ""
            let binding = Binding<String>(
                get: { current },
                set: { [d = context.dispatcher] new in d?.send(event, .string(new)) }
            )
            Picker(selection: binding) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, opt in
                    self.renderChildren(opt.label).tag(Self.stringValue(opt.tag) ?? "")
                }
            } label: {
                renderChildren(label)
            }
        }
    }

    #if !os(tvOS)
    /// A real `DatePicker` bound to a `Binding<Date>` (epoch bridge), honoring the
    /// displayed components + optional epoch bounds.
    @ViewBuilder
    func datePicker(label: [ViewNode], selection: Binding<Date>, components: String,
                    minE: Double?, maxE: Double?) -> some View {
        let comps = dateComponents(components)
        if let minE, let maxE {
            DatePicker(selection: selection,
                       in: Date(timeIntervalSince1970: minE)...Date(timeIntervalSince1970: maxE),
                       displayedComponents: comps) { renderChildren(label) }
        } else if let minE {
            DatePicker(selection: selection, in: Date(timeIntervalSince1970: minE)...,
                       displayedComponents: comps) { renderChildren(label) }
        } else if let maxE {
            DatePicker(selection: selection, in: ...Date(timeIntervalSince1970: maxE),
                       displayedComponents: comps) { renderChildren(label) }
        } else {
            DatePicker(selection: selection, displayedComponents: comps) { renderChildren(label) }
        }
    }

    func dateComponents(_ s: String) -> DatePickerComponents {
        switch s {
        case "date": return [.date]
        case "hourAndMinute": return [.hourAndMinute]
        default: return [.date, .hourAndMinute]
        }
    }
    #endif

    /// A bound `NavigationStack(path:)` + value-based destinations. The SDK owns the
    /// path via a wrapper View (`NavStackPathHost`) that holds the real `@State
    /// path`; GET returns the guest token list, SET dispatches the new `.array`.
    @ViewBuilder
    func navigationStackPath(path: [String], root: [ViewNode],
                             destinations: [IRNavDestination], event: EventID) -> some View {
        #if os(watchOS)
        // No NavigationStack(path:) on watchOS — render the root only (links degrade).
        renderChildren(root)
        #else
        if #available(iOS 16, macOS 13, tvOS 16, *) {
            NavStackPathHost(path: path, event: event, dispatcher: context.dispatcher,
                             root: { self.renderChildren(root) },
                             destinationFor: { token in
                                 // Resolve the pushed token to its destination body.
                                 // The token's typeTag is matched against the
                                 // registered destinations (the pushed value itself is
                                 // a guest input already lowered into the body).
                                 if let dest = destinations.first(where: { token.hasPrefix($0.typeTag) }) {
                                     return self.renderChildren(dest.body)
                                 }
                                 return AnyView(EmptyView())
                             })
        } else {
            renderChildren(root)
        }
        #endif
    }

    /// A real bound `TabView(selection:)`. The selection `Binding` GET returns the
    /// guest's current tab tag; SET dispatches the tapped tab's tag. Int/String tags.
    @ViewBuilder
    func boundTabView(selection: IRValue, kind: IRSelectionKind, tabs: [IRTab],
                      style: IRTabViewStyle, event: EventID) -> some View {
        switch kind {
        case .int:
            let current = Self.intValue(selection) ?? 0
            let binding = Binding<Int>(
                get: { current },
                set: { [d = context.dispatcher] new in d?.send(event, .int(new)) }
            )
            styledTabView(style: style) {
                AnyView(TabView(selection: binding) {
                    ForEach(Array(tabs.enumerated()), id: \.offset) { idx, tab in
                        self.renderChildren(tab.content)
                            .tabItem { self.renderChildren(tab.tabItem) }
                            .tag(Int(tab.tag) ?? idx)
                    }
                })
            }
        case .string:
            let current = Self.stringValue(selection) ?? ""
            let binding = Binding<String>(
                get: { current },
                set: { [d = context.dispatcher] new in d?.send(event, .string(new)) }
            )
            styledTabView(style: style) {
                AnyView(TabView(selection: binding) {
                    ForEach(Array(tabs.enumerated()), id: \.offset) { _, tab in
                        self.renderChildren(tab.content)
                            .tabItem { self.renderChildren(tab.tabItem) }
                            .tag(tab.tag)
                    }
                })
            }
        }
    }

    @ViewBuilder
    private func styledTabView(style: IRTabViewStyle, _ make: () -> AnyView) -> some View {
        switch style {
        case .automatic:
            make()
        case .page:
            #if os(iOS) || os(watchOS) || os(visionOS)
            make().tabViewStyle(.page)
            #else
            make()
            #endif
        }
    }

    /// Replay a `[IRToolbarItem]` as a real `.toolbar { … }`. Each item's content is
    /// a lowered subtree (usually an auto-wired Button) at its placement. Each item
    /// is applied as its OWN `.toolbar { ToolbarItem(placement:) { … } }` (folded
    /// over the items) — a `ForEach` inside the toolbar builder produces `View`, not
    /// `ToolbarContent`, so we chain a modifier per item instead (each is valid
    /// `some ToolbarContent`), which also keeps mixed placements correct.
    private func applyToolbar(_ items: [IRToolbarItem], to v: AnyView) -> AnyView {
        var out = v
        for item in items {
            let placement = toolbarPlacement(item.placement)
            let content = renderChildren(item.content)
            out = AnyView(out.toolbar {
                ToolbarItem(placement: placement) { content }
            })
        }
        return out
    }

    func toolbarPlacement(_ s: String) -> ToolbarItemPlacement {
        switch s {
        case "principal": return .principal
        case "primaryAction": return .primaryAction
        case "confirmationAction": return .confirmationAction
        case "cancellationAction": return .cancellationAction
        case "destructiveAction": return .destructiveAction
        case "status": return .status
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        case "navigationBarLeading", "topBarLeading": return .navigationBarLeading
        case "navigationBarTrailing", "topBarTrailing": return .navigationBarTrailing
        case "bottomBar": return .bottomBar
        case "keyboard":
            if #available(iOS 15, *) { return .keyboard }
            return .automatic
        #endif
        default: return .automatic
        }
    }

    /// Extract a `.int` (coercing `.double`) from an `IRValue` selection tag.
    static func intValue(_ v: IRValue) -> Int? {
        switch v {
        case .int(let i): return i
        case .double(let d): return Int(d)
        default: return nil
        }
    }
    /// Extract a `.string` from an `IRValue` selection tag.
    static func stringValue(_ v: IRValue) -> String? {
        if case .string(let s) = v { return s }
        return nil
    }

    /// The sRGB components of a `Color` (for `ColorPicker` write-back). Resolves via
    /// the platform color so the round-trip carries the user's pick faithfully.
    static func rgbaComponents(_ color: Color) -> (Double, Double, Double, Double) {
        #if canImport(UIKit)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b), Double(a))
        #elseif canImport(AppKit)
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        return (Double(ns.redComponent), Double(ns.greenComponent),
                Double(ns.blueComponent), Double(ns.alphaComponent))
        #else
        return (0, 0, 0, 1)
        #endif
    }

    // MARK: - Canvas (C) — replay serialized draw ops via a real GraphicsContext

    /// A REAL `Canvas` replaying `[IRDrawOp]` with the in-binary `GraphicsContext`.
    /// `Canvas` is iOS 15+/macOS 12+/tvOS 15+/watchOS 8+; degrade to `EmptyView`
    /// where unavailable (a Canvas can't be approximated, so a no-op is honest).
    func canvasView(_ ops: [IRDrawOp]) -> AnyView {
        if #available(iOS 15, macOS 12, tvOS 15, watchOS 8, visionOS 1, *) {
            // The `drawText` ops resolve a Text leaf; we pre-render each op's Text to a
            // real `Text` value so the GraphicsContext can resolve it. Capturing the
            // ops keeps the Canvas closure `Sendable`-clean.
            return AnyView(Canvas { ctx, size in
                Self.replayCanvas(ops, into: &ctx, size: size)
            })
        }
        return AnyView(EmptyView())
    }

    /// Replay the draw ops into a live `GraphicsContext`. Each op carries concrete
    /// scalar geometry the guest computed, so this is a faithful, native-code-free
    /// replay. A `drawText` op resolves its lowered Text leaf to a real `Text`.
    @available(iOS 15, macOS 12, tvOS 15, watchOS 8, visionOS 1, *)
    static func replayCanvas(_ ops: [IRDrawOp], into ctx: inout GraphicsContext, size: CGSize) {
        let r = Renderer(context: RenderContext(showOpaqueStubs: false))
        for op in ops {
            switch op {
            case .fillPath(let commands, let style):
                ctx.fill(r.buildPath(commands), with: r.canvasShading(style))
            case .strokePath(let commands, let style, let lineWidth):
                ctx.stroke(r.buildPath(commands), with: r.canvasShading(style),
                           lineWidth: CGFloat(lineWidth))
            case .drawText(let textNodes, let x, let y, let anchor):
                let text = r.resolveTextLeaf(textNodes)
                let resolved = ctx.resolve(text)
                ctx.draw(resolved, at: CGPoint(x: x, y: y), anchor: r.canvasAnchor(anchor))
            }
        }
    }

    /// Map an `IRShapeStyle` to a `GraphicsContext.Shading`. A color/gradient/material
    /// resolves; anything else falls back to the foreground (never traps).
    @available(iOS 15, macOS 12, tvOS 15, watchOS 8, visionOS 1, *)
    func canvasShading(_ s: IRShapeStyle) -> GraphicsContext.Shading {
        switch s {
        case .color(let c):
            return .color(color(c))
        case .linearGradient(let g, let sp, let ep):
            return .linearGradient(gradientValue(g), startPoint: cgPoint(sp, in: CGSize(width: 1, height: 1)),
                                   endPoint: cgPoint(ep, in: CGSize(width: 1, height: 1)))
        default:
            // Materials / hierarchical / semantic styles aren't `Shading` cases;
            // resolve to the style's nearest color (foreground) so the draw is faithful
            // enough and never traps.
            return .style(renderShapeStyle(s))
        }
    }

    /// A `Gradient` from an `IRGradient` (Canvas shadings take `Gradient`, not the
    /// `LinearGradient` view).
    func gradientValue(_ g: IRGradient) -> Gradient {
        Gradient(stops: g.stops.map { Gradient.Stop(color: color($0.color), location: CGFloat($0.location)) })
    }

    /// A unit point mapped into a concrete CGPoint within `size` (Canvas gradients
    /// take absolute points, not UnitPoints).
    private func cgPoint(_ p: IRUnitPoint, in size: CGSize) -> CGPoint {
        let u = unitPointValue(p)
        return CGPoint(x: u.x * size.width, y: u.y * size.height)
    }

    /// Resolve a lowered Text-leaf subtree (a `text`/`styledText` node + its
    /// font/color modifiers) into a real `Text` for `ctx.draw`. A non-Text leaf
    /// degrades to an empty `Text` (the op renders nothing rather than trapping).
    func resolveTextLeaf(_ nodes: [ViewNode]) -> Text {
        guard let node = nodes.first else { return Text("") }
        var text: Text
        switch node.kind {
        case .text(let s): text = Text(s)
        case .styledText(let s, let v, let m, let l):
            text = styledText(s, verbatim: v, markdown: m, localized: l)
        default: text = Text("")
        }
        // Apply the Text-level modifiers the leaf carried (font/color/bold/italic).
        for mod in node.modifiers {
            switch mod {
            case .font(let f): text = text.font(font(f))
            case .foregroundColor(let c): text = text.foregroundColor(color(c))
            case .bold: text = text.bold()
            case .italic: text = text.italic()
            default: break
            }
        }
        return text
    }

    /// A named UnitPoint anchor for `ctx.draw(_:at:anchor:)` (default `.center`).
    func canvasAnchor(_ s: String) -> UnitPoint {
        switch s {
        case "topLeading": return .topLeading
        case "top": return .top
        case "topTrailing": return .topTrailing
        case "leading": return .leading
        case "trailing": return .trailing
        case "bottomLeading": return .bottomLeading
        case "bottom": return .bottom
        case "bottomTrailing": return .bottomTrailing
        default: return .center
        }
    }
}

// MARK: - Host-state wrapper Views (own real SwiftUI state the Renderer can't)

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if !os(tvOS)
/// Owns a real `@FocusState<String?>` and binds it to the guest's focus token.
/// A `View` can hold `@FocusState`; the `Renderer` struct cannot — so `.focused`
/// renders through this wrapper. The field is focused when the guest's focus value
/// equals this field's `fieldToken`; a focus CHANGE dispatches the new token (or
/// "" when this field loses focus), so the guest's focus model stays authoritative.
@MainActor
struct FocusBinder: View {
    let content: AnyView
    let fieldToken: String
    let isFocused: Bool
    let dispatcher: Dispatcher?
    let event: EventID
    @FocusState private var focused: Bool

    var body: some View {
        content
            .focused($focused)
            .onChange(of: isFocused) { newValue in
                // Guest → host: reflect the guest's authoritative focus into the
                // real @FocusState (so a programmatic `focus = field` focuses it).
                if focused != newValue { focused = newValue }
            }
            .onChange(of: focused) { nowFocused in
                // Host → guest: a tap/Tab focus change dispatches the new token.
                dispatcher?.send(event, .string(nowFocused ? fieldToken : ""))
            }
            .onAppear { if focused != isFocused { focused = isFocused } }
    }
}
#endif

#if !os(watchOS)
/// Owns a real `@State path: [String]` and binds it to `NavigationStack(path:)`.
/// GET returns the guest's token list (the source of truth); a SwiftUI-initiated
/// push/pop (a value-link tap or a back-swipe) updates the local state, which
/// `onChange` forwards to the guest as the new `.array([.string])` path. A
/// destination is resolved by the enclosing renderer's `destinationFor`.
@available(iOS 16, macOS 13, tvOS 16, *)
@MainActor
struct NavStackPathHost: View {
    let initialPath: [String]
    let event: EventID
    let dispatcher: Dispatcher?
    let root: () -> AnyView
    let destinationFor: (String) -> AnyView
    @State private var path: [String]

    init(path: [String], event: EventID, dispatcher: Dispatcher?,
         root: @escaping () -> AnyView, destinationFor: @escaping (String) -> AnyView) {
        self.initialPath = path
        self.event = event
        self.dispatcher = dispatcher
        self.root = root
        self.destinationFor = destinationFor
        _path = State(initialValue: path)
    }

    var body: some View {
        NavigationStack(path: $path) {
            root()
                .navigationDestination(for: String.self) { token in
                    destinationFor(token)
                }
        }
        // Guest → host: when the guest re-emits a new path (e.g. a `dismiss()`
        // cleared the last token), reflect it into the real state.
        .onChange(of: initialPath) { newValue in
            if path != newValue { path = newValue }
        }
        // Host → guest: a SwiftUI push/pop changed the path — forward it so the
        // guest's path model stays authoritative.
        .onChange(of: path) { newValue in
            dispatcher?.send(event, .array(newValue.map { .string($0) }))
        }
    }
}
#endif

/// Owns a REAL `GeometryReader { proxy in … }` and re-evaluates the lowered child
/// body against the live proxy. On each layout pass the proxy's `size` /
/// `frame(in:.local)` are passed to `rebuild` (which re-invokes the guest's
/// `view_body` with those values merged as reserved `__geo_*` inputs and returns
/// THIS reader's children from the re-emitted tree); the children render through
/// `renderChildren`. When `rebuild` is nil or returns nil (no live module / decode
/// failure), the statically-lowered `staticChildren` render — so a bare
/// `render(_:)` (and any rebuild failure) degrades to the emit-time layout, never a
/// hole. `GeometryReader` is available on every SwiftUI platform.
@MainActor
struct GeometryReaderHost: View {
    let id: String
    let staticChildren: [ViewNode]
    let rebuild: GeometryRebuild?
    let renderChildren: ([ViewNode]) -> AnyView

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .local)
            let fresh = rebuild?(id, Double(proxy.size.width), Double(proxy.size.height),
                                 Double(frame.minX), Double(frame.minY))
            renderChildren(fresh ?? staticChildren)
        }
    }
}
#endif
