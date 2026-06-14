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
    /// `Text` with a content flag (`verbatim`/`markdown`/`localized`).
    public static func styledText(_ s: String, verbatim: Bool = false,
                                  markdown: Bool = false, localized: Bool = false) -> ViewNode {
        ViewNode(.styledText(s, verbatim: verbatim, markdown: markdown, localized: localized))
    }
    /// `Text(date, style:)` — `epoch` is seconds since 1970.
    public static func dateText(epoch: Double, style: IRDateTextStyle) -> ViewNode {
        ViewNode(.dateText(epoch: epoch, style: style))
    }
    public static func image(systemName: String) -> ViewNode { ViewNode(.image(systemName: systemName)) }
    /// `Image(systemName:, variableValue:)`.
    public static func symbolImage(systemName: String, variableValue: Double? = nil) -> ViewNode {
        ViewNode(.symbolImage(systemName: systemName, variableValue: variableValue))
    }
    /// `Image("assetName")` — a bundled Asset-Catalog image.
    public static func bundleImage(name: String) -> ViewNode { ViewNode(.bundleImage(name: name)) }
    /// `AsyncImage(url:, scale:)` — the real async image loader.
    public static func asyncImage(url: String, scale: Double? = nil) -> ViewNode {
        ViewNode(.asyncImage(url: url, scale: scale))
    }
    public static func spacer(minLength: Double? = nil) -> ViewNode { ViewNode(.spacer(minLength: minLength)) }
    public static var divider: ViewNode { ViewNode(.divider) }
    public static func color(_ c: ColorRef) -> ViewNode { ViewNode(.color(c)) }
    public static func color(named: String) -> ViewNode { ViewNode(.color(.named(named))) }
    public static func shape(_ k: ShapeKind) -> ViewNode { ViewNode(.shape(k)) }
    /// A declarative `Path { … }` of concrete scalar commands.
    public static func path(_ commands: [IRPathCommand]) -> ViewNode { ViewNode(.path(commands: commands)) }
    /// An indeterminate `ProgressView()` spinner.
    public static var progressView: ViewNode { ViewNode(.progressView) }
    /// A determinate `ProgressView(value:total:) { label }`.
    public static func progressView(value: Double, total: Double = 1,
                                    label: [ViewNode] = []) -> ViewNode {
        ViewNode(.determinateProgress(value: value, total: total, label: label))
    }
    /// `Gauge(value:in:) { label }`.
    public static func gauge(value: Double, min: Double = 0, max: Double = 1,
                             label: [ViewNode] = []) -> ViewNode {
        ViewNode(.gauge(data: IRGaugeData(value: value, min: min, max: max), label: label))
    }
    /// `Link(destination:) { label }`.
    public static func link(destination: String, label: [ViewNode]) -> ViewNode {
        ViewNode(.link(destination: destination, label: label))
    }
    /// `ShareLink(items:) { label }` (label may be empty for the default form).
    public static func shareLink(items: [String], label: [ViewNode] = []) -> ViewNode {
        ViewNode(.shareLink(items: items, label: label))
    }
    /// `SecureField(placeholder, text: $s)`.
    public static func secureField(_ placeholder: String, text: String, event: String) -> ViewNode {
        ViewNode(.secureField(placeholder: placeholder, value: text, event: EventID(event)))
    }
    /// `TextEditor(text: $s)`.
    public static func textEditor(text: String, event: String) -> ViewNode {
        ViewNode(.textEditor(value: text, event: EventID(event)))
    }
    /// `LabeledContent { content } label: { label }`.
    public static func labeledContent(label: [ViewNode], content: [ViewNode]) -> ViewNode {
        ViewNode(.labeledContent(label: label, content: content))
    }
    /// `Menu { items } label: { label }`.
    public static func menu(label: [ViewNode], items: [ViewNode]) -> ViewNode {
        ViewNode(.menu(label: label, items: items))
    }

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

    // Containers — IR v2 (more of a real screen rides WASM).
    public static func scrollView(axis: IRScrollAxis = .vertical,
                                  _ children: [ViewNode]) -> ViewNode {
        ViewNode(.scrollView(axis: axis, children: children))
    }
    public static func list(_ children: [ViewNode]) -> ViewNode {
        ViewNode(.list(children: children))
    }
    public static func section(header: [ViewNode] = [], footer: [ViewNode] = [],
                               _ content: [ViewNode]) -> ViewNode {
        ViewNode(.section(header: header, footer: footer, content: content))
    }
    public static func form(_ children: [ViewNode]) -> ViewNode {
        ViewNode(.form(children: children))
    }
    public static func navigationStack(_ children: [ViewNode]) -> ViewNode {
        ViewNode(.navigationStack(children: children))
    }

    // Containers — leaf-views + container expansion.
    public static func lazyVStack(alignment: IRHorizontalAlignment? = nil,
                                  spacing: Double? = nil, _ children: [ViewNode]) -> ViewNode {
        ViewNode(.lazyVStack(alignment: alignment, spacing: spacing, children: children))
    }
    public static func lazyHStack(alignment: IRVerticalAlignment? = nil,
                                  spacing: Double? = nil, _ children: [ViewNode]) -> ViewNode {
        ViewNode(.lazyHStack(alignment: alignment, spacing: spacing, children: children))
    }
    public static func lazyVGrid(columns: [IRGridItem], spacing: Double? = nil,
                                 _ children: [ViewNode]) -> ViewNode {
        ViewNode(.lazyVGrid(columns: columns, spacing: spacing, children: children))
    }
    public static func lazyHGrid(rows: [IRGridItem], spacing: Double? = nil,
                                 _ children: [ViewNode]) -> ViewNode {
        ViewNode(.lazyHGrid(rows: rows, spacing: spacing, children: children))
    }
    public static func grid(alignment: IRAlignment? = nil, horizontalSpacing: Double? = nil,
                            verticalSpacing: Double? = nil, _ children: [ViewNode]) -> ViewNode {
        ViewNode(.grid(alignment: alignment, horizontalSpacing: horizontalSpacing,
                       verticalSpacing: verticalSpacing, children: children))
    }
    public static func gridRow(alignment: IRVerticalAlignment? = nil,
                               _ children: [ViewNode]) -> ViewNode {
        ViewNode(.gridRow(alignment: alignment, children: children))
    }
    public static func groupBox(label: [ViewNode] = [], _ children: [ViewNode]) -> ViewNode {
        ViewNode(.groupBox(label: label, children: children))
    }
    public static func disclosureGroup(label: [ViewNode], _ children: [ViewNode]) -> ViewNode {
        ViewNode(.disclosureGroup(label: label, children: children))
    }
    public static func viewThatFits(axes: IRAxisSet = .both, _ children: [ViewNode]) -> ViewNode {
        ViewNode(.viewThatFits(axes: axes, children: children))
    }
    public static func controlGroup(_ children: [ViewNode]) -> ViewNode {
        ViewNode(.controlGroup(children: children))
    }
    public static func tabView(tabs: [IRTab], style: IRTabViewStyle = .automatic) -> ViewNode {
        ViewNode(.tabView(tabs: tabs, style: style))
    }

    // Interaction
    public static func button(actionID: String, role: IRButtonRole? = nil,
                              label: [ViewNode]) -> ViewNode {
        ViewNode(.button(actionID: actionID, role: role, label: label))
    }
    public static func button(_ title: String, actionID: String,
                              role: IRButtonRole? = nil) -> ViewNode {
        ViewNode(.button(actionID: actionID, role: role, label: [N.text(title)]))
    }

    /// `Label { title } icon: { icon }` — the general form.
    public static func label(title: [ViewNode], icon: [ViewNode]) -> ViewNode {
        ViewNode(.label(title: title, icon: icon))
    }
    /// `Label("Title", systemImage: "house")` convenience — emits a Text title +
    /// an SF-symbol Image icon.
    public static func label(title: String, systemImage: String) -> ViewNode {
        ViewNode(.label(title: [N.text(title)], icon: [N.image(systemName: systemImage)]))
    }
    /// `content.contextMenu { items }`.
    public static func contextMenu(content: [ViewNode], items: [ViewNode]) -> ViewNode {
        ViewNode(.contextMenu(content: content, items: items))
    }

    // Stateful controls (INTERACTIVE — Breakthrough #5). The `value` is read
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

    // Host-state controls (B — selection / navigation). `event` is dispatched back
    // into the guest on a user-initiated change (incl. system swipe/tab/back).

    /// `Picker(selection: $sel) { options } label: { label }` (Int-tagged).
    public static func picker(label: [ViewNode], selection: Int, options: [IRPickerOption],
                              event: String) -> ViewNode {
        ViewNode(.picker(label: label, selection: .int(selection), kind: .int,
                         options: options, event: EventID(event)))
    }
    /// `Picker(selection: $sel) { options } label: { label }` (String-tagged).
    public static func picker(label: [ViewNode], selection: String, options: [IRPickerOption],
                              event: String) -> ViewNode {
        ViewNode(.picker(label: label, selection: .string(selection), kind: .string,
                         options: options, event: EventID(event)))
    }
    /// `DatePicker(label, selection: $date, displayedComponents:)`.
    public static func datePicker(label: [ViewNode], epoch: Double,
                                  components: String = "dateAndTime",
                                  minEpoch: Double? = nil, maxEpoch: Double? = nil,
                                  event: String) -> ViewNode {
        ViewNode(.datePicker(label: label, epoch: epoch, components: components,
                             minEpoch: minEpoch, maxEpoch: maxEpoch, event: EventID(event)))
    }
    /// `ColorPicker(label, selection: $color, supportsOpacity:)`.
    public static func colorPicker(label: [ViewNode], color: IRColor,
                                   supportsOpacity: Bool = true, event: String) -> ViewNode {
        ViewNode(.colorPicker(label: label, color: color,
                              supportsOpacity: supportsOpacity, event: EventID(event)))
    }
    /// `NavigationLink(destination:) { label }` — the eager form.
    public static func navigationLink(destination: [ViewNode], label: [ViewNode]) -> ViewNode {
        ViewNode(.navigationLink(destination: destination, label: label))
    }
    /// `NavigationStack(path: $path) { root }` + `.navigationDestination(for:)`s.
    public static func navigationStack(path: [String], root: [ViewNode],
                                       destinations: [IRNavDestination], event: String) -> ViewNode {
        ViewNode(.navigationStackPath(path: path, root: root,
                                      destinations: destinations, event: EventID(event)))
    }
    /// `DisclosureGroup(isExpanded: $flag) { content } label: { label }` (bound).
    public static func disclosureGroup(label: [ViewNode], isExpanded: Bool,
                                       _ content: [ViewNode], event: String) -> ViewNode {
        ViewNode(.boundDisclosureGroup(label: label, isExpanded: isExpanded,
                                       content: content, event: EventID(event)))
    }
    /// `Section(isExpanded: $flag) { content } header: { header }` (bound).
    public static func section(header: [ViewNode], isExpanded: Bool,
                               _ content: [ViewNode], event: String) -> ViewNode {
        ViewNode(.boundSection(header: header, isExpanded: isExpanded,
                               content: content, event: EventID(event)))
    }
    /// `TabView(selection: $sel) { tabs }` (bound, Int-tagged).
    public static func tabView(selection: Int, tabs: [IRTab],
                               style: IRTabViewStyle = .automatic, event: String) -> ViewNode {
        ViewNode(.boundTabView(selection: .int(selection), kind: .int,
                               tabs: tabs, style: style, event: EventID(event)))
    }
    /// `TabView(selection: $sel) { tabs }` (bound, String-tagged).
    public static func tabView(selection: String, tabs: [IRTab],
                               style: IRTabViewStyle = .automatic, event: String) -> ViewNode {
        ViewNode(.boundTabView(selection: .string(selection), kind: .string,
                               tabs: tabs, style: style, event: EventID(event)))
    }
    /// `EditButton()` — toggles the SDK-owned EditMode.
    public static var editButton: ViewNode { ViewNode(.editButton) }

    /// `GeometryReader { proxy in <body> }` — the lowered `children` read the
    /// reserved geo inputs (`__geo_width`/`__geo_height`/`__geo_minX`/`__geo_minY`)
    /// the SDK host wrapper injects from the live `GeometryProxy`. `id` is a
    /// content-stable token (the engine derives it from the closure source) so the
    /// host can re-locate this reader in the re-emitted tree on a size change.
    public static func geometryReader(id: String, _ children: [ViewNode]) -> ViewNode {
        ViewNode(.geometryReader(id: id, children: children))
    }

    /// `Canvas { ctx, size in <draws> }` — `ops` are replayed by a real host
    /// `Canvas` via the in-binary `GraphicsContext`.
    public static func canvas(_ ops: [IRDrawOp]) -> ViewNode {
        ViewNode(.canvas(ops: ops))
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
    /// `.font(<design-system token>)` — the font value is host-supplied (the thunk's
    /// `__patchTokens()[id]`), keyed by the content-stable `id` the build emitted.
    public func fontToken(_ id: String) -> ViewNode { with(.fontToken(id)) }
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
    /// A flexible `.frame(...)`: any subset of bounds, each an `IRLength`
    /// (`.points(x)` or `.infinity`). Mirrors SwiftUI's flexible frame overload.
    public func flexFrame(minWidth: IRLength? = nil, idealWidth: IRLength? = nil,
                          maxWidth: IRLength? = nil, minHeight: IRLength? = nil,
                          idealHeight: IRLength? = nil, maxHeight: IRLength? = nil,
                          alignment: IRAlignment? = nil) -> ViewNode {
        with(.flexFrame(minWidth: minWidth, idealWidth: idealWidth, maxWidth: maxWidth,
                        minHeight: minHeight, idealHeight: idealHeight, maxHeight: maxHeight,
                        alignment: alignment))
    }
    public func tint(_ c: ColorRef) -> ViewNode { with(.tint(c)) }
    public func clipShape(_ k: ShapeKind) -> ViewNode { with(.clipShape(k)) }
    public func disabled(_ b: Bool) -> ViewNode { with(.disabled(b)) }
    public func fixedSize() -> ViewNode { with(.fixedSize) }
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
    /// `.navigationTitle("Title")`.
    public func navigationTitle(_ title: String) -> ViewNode { with(.navigationTitle(title)) }

    // MARK: Styling (IRShapeStyle vocabulary)

    public func foregroundStyle(_ layers: [IRShapeStyle]) -> ViewNode { with(.foregroundStyle(layers)) }
    public func foregroundStyle(_ s: IRShapeStyle) -> ViewNode { with(.foregroundStyle([s])) }
    public func background(alignment: IRAlignment? = nil, _ content: [ViewNode]) -> ViewNode {
        with(.backgroundContent(alignment: alignment, content: content))
    }
    public func background(_ style: IRShapeStyle, in shape: ShapeKind? = nil) -> ViewNode {
        with(.backgroundStyle(style, in: shape))
    }
    public func tint(_ style: IRShapeStyle) -> ViewNode { with(.tintStyle(style)) }
    public func fill(_ style: IRShapeStyle, eoFill: Bool = false) -> ViewNode { with(.fill(style, eoFill: eoFill)) }
    public func stroke(_ style: IRShapeStyle, _ stroke: IRStrokeStyle = IRStrokeStyle()) -> ViewNode {
        with(.stroke(style, stroke))
    }
    public func strokeBorder(_ style: IRShapeStyle, _ stroke: IRStrokeStyle = IRStrokeStyle()) -> ViewNode {
        with(.strokeBorder(style, stroke))
    }
    public func border(_ style: IRShapeStyle, width: Double = 1) -> ViewNode { with(.border(style, width: width)) }
    public func overlay(alignment: IRAlignment? = nil, _ content: [ViewNode]) -> ViewNode {
        with(.overlayContent(alignment: alignment, content: content))
    }
    public func overlay(_ style: IRShapeStyle, in shape: ShapeKind) -> ViewNode {
        with(.overlayStyle(style, in: shape))
    }
    public func shadow(color: ColorRef? = nil, radius: Double, x: Double = 0, y: Double = 0) -> ViewNode {
        with(.shadow(color: color, radius: radius, x: x, y: y))
    }
    public func mask(alignment: IRAlignment? = nil, _ content: [ViewNode]) -> ViewNode {
        with(.mask(alignment: alignment, content: content))
    }

    // MARK: Layout

    public func offset(x: Double = 0, y: Double = 0) -> ViewNode { with(.offset(x: x, y: y)) }
    public func position(x: Double, y: Double) -> ViewNode { with(.position(x: x, y: y)) }
    public func aspectRatio(_ ratio: Double? = nil, contentMode: IRContentMode) -> ViewNode {
        with(.aspectRatio(ratio: ratio, contentMode))
    }
    public func scaledToFit() -> ViewNode { with(.aspectRatio(ratio: nil, .fit)) }
    public func scaledToFill() -> ViewNode { with(.aspectRatio(ratio: nil, .fill)) }
    public func clipped(antialiased: Bool = false) -> ViewNode { with(.clipped(antialiased: antialiased)) }
    public func fixedSize(horizontal: Bool, vertical: Bool) -> ViewNode {
        with(.fixedSizeAxis(horizontal: horizontal, vertical: vertical))
    }
    public func layoutPriority(_ p: Double) -> ViewNode { with(.layoutPriority(p)) }
    public func safeAreaInset(edge: String, alignment: IRAlignment? = nil,
                              spacing: Double? = nil, _ content: [ViewNode]) -> ViewNode {
        with(.safeAreaInset(edge: edge, alignment: alignment, spacing: spacing, content: content))
    }
    public func ignoresSafeArea(regions: String = "all", edges: String = "all") -> ViewNode {
        with(.ignoresSafeArea(regions: regions, edges: edges))
    }
    public func zIndex(_ z: Double) -> ViewNode { with(.zIndex(z)) }
    public func containerRelativeFrame(axes: String, alignment: IRAlignment? = nil) -> ViewNode {
        with(.containerRelativeFrame(axes: axes, alignment: alignment))
    }

    // MARK: Transforms & visual effects

    public func rotationEffect(degrees: Double, anchor: IRUnitPoint? = nil) -> ViewNode {
        with(.rotationEffect(degrees: degrees, anchor: anchor))
    }
    public func rotation3DEffect(degrees: Double, x: Double, y: Double, z: Double,
                                 anchor: IRUnitPoint? = nil, anchorZ: Double = 0,
                                 perspective: Double = 1) -> ViewNode {
        with(.rotation3DEffect(degrees: degrees, x: x, y: y, z: z,
                               anchor: anchor, anchorZ: anchorZ, perspective: perspective))
    }
    public func scaleEffect(x: Double, y: Double, anchor: IRUnitPoint? = nil) -> ViewNode {
        with(.scaleEffect(x: x, y: y, anchor: anchor))
    }
    public func blur(radius: Double, opaque: Bool = false) -> ViewNode { with(.blur(radius: radius, opaque: opaque)) }
    public func brightness(_ v: Double) -> ViewNode { with(.brightness(v)) }
    public func contrast(_ v: Double) -> ViewNode { with(.contrast(v)) }
    public func saturation(_ v: Double) -> ViewNode { with(.saturation(v)) }
    public func grayscale(_ v: Double) -> ViewNode { with(.grayscale(v)) }
    public func hueRotation(degrees: Double) -> ViewNode { with(.hueRotation(degrees: degrees)) }
    public func colorInvert() -> ViewNode { with(.colorInvert) }
    public func blendMode(_ m: IRBlendMode) -> ViewNode { with(.blendMode(m)) }

    // MARK: Text styling

    public func fontWeight(_ w: IRFont.Weight?) -> ViewNode { with(.fontWeight(w)) }
    public func fontDesign(_ d: IRFont.Design?) -> ViewNode { with(.fontDesign(d)) }
    public func underline(_ active: Bool = true, color: ColorRef? = nil) -> ViewNode {
        with(.underline(active: active, color: color))
    }
    public func strikethrough(_ active: Bool = true, color: ColorRef? = nil) -> ViewNode {
        with(.strikethrough(active: active, color: color))
    }
    public func kerning(_ v: Double) -> ViewNode { with(.kerning(v)) }
    public func tracking(_ v: Double) -> ViewNode { with(.tracking(v)) }
    public func baselineOffset(_ v: Double) -> ViewNode { with(.baselineOffset(v)) }
    public func lineSpacing(_ v: Double) -> ViewNode { with(.lineSpacing(v)) }
    public func textCase(_ c: String?) -> ViewNode { with(.textCase(c)) }
    public func minimumScaleFactor(_ v: Double) -> ViewNode { with(.minimumScaleFactor(v)) }
    public func truncationMode(_ m: String) -> ViewNode { with(.truncationMode(m)) }
    public func monospaced() -> ViewNode { with(.monospaced) }
    public func monospacedDigit() -> ViewNode { with(.monospacedDigit) }
    public func redacted(reason: String) -> ViewNode { with(.redacted(reason: reason)) }
    public func unredacted() -> ViewNode { with(.unredacted) }
    public func symbolRenderingMode(_ m: String) -> ViewNode { with(.symbolRenderingMode(m)) }
    public func symbolVariant(_ v: String) -> ViewNode { with(.symbolVariant(v)) }
    public func imageScale(_ s: String) -> ViewNode { with(.imageScale(s)) }
    public func dynamicTypeSize(_ s: String) -> ViewNode { with(.dynamicTypeSize(s)) }

    // MARK: Control config

    public func buttonStyle(_ s: IRButtonStyle) -> ViewNode { with(.buttonStyle(s)) }
    public func listStyle(_ s: IRListStyle) -> ViewNode { with(.listStyle(s)) }
    public func pickerStyle(_ s: String) -> ViewNode { with(.pickerStyle(s)) }
    public func toggleStyle(_ s: String) -> ViewNode { with(.toggleStyle(s)) }
    public func labelStyle(_ s: String) -> ViewNode { with(.labelStyle(s)) }
    public func gaugeStyle(_ s: String) -> ViewNode { with(.gaugeStyle(s)) }
    public func progressViewStyle(_ s: String) -> ViewNode { with(.progressViewStyle(s)) }
    public func menuStyle(_ s: String) -> ViewNode { with(.menuStyle(s)) }
    public func buttonBorderShape(_ s: String) -> ViewNode { with(.buttonBorderShape(s)) }
    public func controlSize(_ s: String) -> ViewNode { with(.controlSize(s)) }
    public func keyboardType(_ s: String) -> ViewNode { with(.keyboardType(s)) }
    public func textContentType(_ s: String) -> ViewNode { with(.textContentType(s)) }
    public func autocorrectionDisabled(_ b: Bool = true) -> ViewNode { with(.autocorrectionDisabled(b)) }
    public func textInputAutocapitalization(_ s: String) -> ViewNode { with(.textInputAutocapitalization(s)) }
    public func submitLabel(_ s: String) -> ViewNode { with(.submitLabel(s)) }
    public func preferredColorScheme(_ s: String?) -> ViewNode { with(.preferredColorScheme(s)) }
    public func accentColor(_ c: ColorRef?) -> ViewNode { with(.accentColor(c)) }

    // MARK: Gestures

    public func onLongPressGesture(minimumDuration: Double = 0.5, event: String) -> ViewNode {
        with(.onLongPressGesture(minimumDuration: minimumDuration, EventID(event)))
    }
    public func dragGesture(minDistance: Double = 10, onChanged: String? = nil, onEnded: String? = nil) -> ViewNode {
        with(.dragGesture(minDistance: minDistance,
                          onChanged: onChanged.map(EventID.init), onEnded: onEnded.map(EventID.init)))
    }
    public func magnifyGesture(event: String) -> ViewNode { with(.magnifyGesture(EventID(event))) }
    public func rotateGesture(event: String) -> ViewNode { with(.rotateGesture(EventID(event))) }

    // MARK: Lifecycle

    public func onAppear(event: String) -> ViewNode { with(.onAppear(EventID(event))) }
    public func onDisappear(event: String) -> ViewNode { with(.onDisappear(EventID(event))) }
    public func onChange(valueKey: String, event: String) -> ViewNode {
        with(.onChange(valueKey: valueKey, EventID(event)))
    }
    public func task(event: String, id: String? = nil) -> ViewNode { with(.task(EventID(event), id: id)) }
    public func onSubmit(event: String) -> ViewNode { with(.onSubmit(EventID(event))) }
    public func onHover(event: String) -> ViewNode { with(.onHover(EventID(event))) }
    public func sensoryFeedback(kind: String, triggerKey: String) -> ViewNode {
        with(.sensoryFeedback(kind: kind, triggerKey: triggerKey))
    }

    // MARK: Animation

    public func animation(_ a: IRAnimation?, valueKey: String) -> ViewNode {
        with(.animation(a, valueKey: valueKey))
    }
    public func transition(_ t: IRTransition) -> ViewNode { with(.transition(t)) }

    // MARK: Host-state — presentation / navigation / focus / list-editing

    public func sheet(presentedKey: String, isPresented: Bool,
                      event: String, _ content: [ViewNode]) -> ViewNode {
        with(.sheet(presentedKey: presentedKey, isPresented: isPresented,
                    content: content, event: EventID(event)))
    }
    public func sheet(itemKey: String, itemPresent: Bool,
                      event: String, _ content: [ViewNode]) -> ViewNode {
        with(.sheetItem(itemKey: itemKey, itemPresent: itemPresent,
                        content: content, event: EventID(event)))
    }
    public func fullScreenCover(presentedKey: String, isPresented: Bool,
                                event: String, _ content: [ViewNode]) -> ViewNode {
        with(.fullScreenCover(presentedKey: presentedKey, isPresented: isPresented,
                              content: content, event: EventID(event)))
    }
    public func popover(presentedKey: String, isPresented: Bool,
                        event: String, _ content: [ViewNode]) -> ViewNode {
        with(.popover(presentedKey: presentedKey, isPresented: isPresented,
                      content: content, event: EventID(event)))
    }
    public func alert(_ title: String, presentedKey: String, isPresented: Bool,
                      event: String, actions: [ViewNode], message: [ViewNode] = []) -> ViewNode {
        with(.alert(title: title, presentedKey: presentedKey, isPresented: isPresented,
                    actions: actions, message: message, event: EventID(event)))
    }
    public func confirmationDialog(_ title: String, titleVisibility: String = "automatic",
                                   presentedKey: String, isPresented: Bool, event: String,
                                   actions: [ViewNode], message: [ViewNode] = []) -> ViewNode {
        with(.confirmationDialog(title: title, titleVisibility: titleVisibility,
                                 presentedKey: presentedKey, isPresented: isPresented,
                                 actions: actions, message: message, event: EventID(event)))
    }
    public func navigationDestination(presentedKey: String, isPresented: Bool,
                                      event: String, _ destination: [ViewNode]) -> ViewNode {
        with(.navigationDestinationBool(presentedKey: presentedKey, isPresented: isPresented,
                                        destination: destination, event: EventID(event)))
    }
    public func toolbar(items: [IRToolbarItem]) -> ViewNode { with(.toolbar(items: items)) }
    public func navigationBarTitleDisplayMode(_ mode: String) -> ViewNode {
        with(.navigationBarTitleDisplayMode(mode))
    }
    public func navigationBarBackButtonHidden(_ hidden: Bool = true) -> ViewNode {
        with(.navigationBarBackButtonHidden(hidden))
    }
    public func searchable(searchKey: String, query: String, prompt: String? = nil,
                           event: String) -> ViewNode {
        with(.searchable(searchKey: searchKey, query: query, prompt: prompt, event: EventID(event)))
    }
    public func focused(focusKey: String, equals token: String, isFocused: Bool,
                        event: String) -> ViewNode {
        with(.focused(focusKey: focusKey, equalsToken: token, isFocused: isFocused,
                      event: EventID(event)))
    }
    public func onDelete(event: String) -> ViewNode { with(.onDelete(EventID(event))) }
    public func onMove(event: String) -> ViewNode { with(.onMove(EventID(event))) }
}
