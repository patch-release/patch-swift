// Describe.swift — a stable, human-readable structural description of a
// ViewNode tree. Two trees that describe identically are structurally identical
// (the renderer is a pure function of the tree, so equal description ⇒ equal
// rendered SwiftUI). This is what the tests use to assert "the view rendered
// from WASM MATCHES the original" without a pixel snapshot (CI is headless).

extension ViewNode {
    public func describe(indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        var line = pad + kindLabel
        if !modifiers.isEmpty {
            line += " " + modifiers.map { $0.label }.joined(separator: " ")
        }
        var out = line
        for child in childNodes {
            out += "\n" + child.describe(indent: indent + 1)
        }
        return out
    }

    var kindLabel: String {
        switch kind {
        case .text(let s): return "Text(\"\(s)\")"
        case .styledText(let s, let v, let m, let l):
            return "StyledText(\"\(s)\",verbatim:\(v),markdown:\(m),localized:\(l))"
        case .dateText(let e, let st): return "DateText(epoch:\(e),style:\(st.rawValue))"
        case .image(let n): return "Image(systemName:\"\(n)\")"
        case .symbolImage(let n, let vv):
            return "Image(systemName:\"\(n)\",variableValue:\(vv.map { String($0) } ?? "nil"))"
        case .bundleImage(let n): return "Image(\"\(n)\")"
        case .asyncImage(let url, let sc):
            return "AsyncImage(url:\"\(url)\",scale:\(sc.map { String($0) } ?? "nil"))"
        case .spacer(let m): return m.map { "Spacer(\($0))" } ?? "Spacer"
        case .divider: return "Divider"
        case .color(let c): return "Color(\(c.label))"
        case .shape(let s): return "Shape(\(s.label))"
        case .path(let cmds): return "Path(\(cmds.count) cmds)"
        case .progressView: return "ProgressView"
        case .determinateProgress(let v, let t, _):
            return "ProgressView(value:\(v),total:\(t))"
        case .gauge(let d, _): return "Gauge(value:\(d.value),in:\(d.min)...\(d.max))"
        case .link(let dest, _): return "Link(destination:\"\(dest)\")"
        case .shareLink(let items, _): return "ShareLink(items:\(items.count))"
        case .secureField(let p, let v, let e):
            return "SecureField(placeholder:\"\(p)\",text:\"\(v)\",event:#\(e.id))"
        case .textEditor(let v, let e): return "TextEditor(text:\"\(v)\",event:#\(e.id))"
        case .labeledContent(let l, let c):
            return "LabeledContent(label:\(l.count),content:\(c.count))"
        case .menu(let l, let items): return "Menu(label:\(l.count),items:\(items.count))"
        case .contextMenu(let c, let items):
            return "ContextMenu(content:\(c.count),items:\(items.count))"
        case .vstack(let a, let sp, _):
            return "VStack(align:\(a?.rawValue ?? "center"),spacing:\(sp.map { String($0) } ?? "nil"))"
        case .hstack(let a, let sp, _):
            return "HStack(align:\(a?.rawValue ?? "center"),spacing:\(sp.map { String($0) } ?? "nil"))"
        case .zstack(let a, _):
            return "ZStack(align:\(a?.rawValue ?? "center"))"
        case .group: return "Group"
        case .forEach: return "ForEach"
        case .scrollView(let axis, _): return "ScrollView(axis:\(axis.rawValue))"
        case .list: return "List"
        case .section(let h, let f, _):
            return "Section(header:\(h.count),footer:\(f.count))"
        case .form: return "Form"
        case .navigationStack: return "NavigationStack"
        case .lazyVStack(let a, let sp, _):
            return "LazyVStack(align:\(a?.rawValue ?? "center"),spacing:\(sp.map { String($0) } ?? "nil"))"
        case .lazyHStack(let a, let sp, _):
            return "LazyHStack(align:\(a?.rawValue ?? "center"),spacing:\(sp.map { String($0) } ?? "nil"))"
        case .lazyVGrid(let cols, let sp, _):
            return "LazyVGrid(cols:\(cols.count),spacing:\(sp.map { String($0) } ?? "nil"))"
        case .lazyHGrid(let rows, let sp, _):
            return "LazyHGrid(rows:\(rows.count),spacing:\(sp.map { String($0) } ?? "nil"))"
        case .grid(let a, let hs, let vs, _):
            return "Grid(align:\(a?.rawValue ?? "center"),h:\(hs.map { String($0) } ?? "nil"),v:\(vs.map { String($0) } ?? "nil"))"
        case .gridRow(let a, _): return "GridRow(align:\(a?.rawValue ?? "center"))"
        case .groupBox(let l, _): return "GroupBox(label:\(l.count))"
        case .disclosureGroup(let l, _): return "DisclosureGroup(label:\(l.count))"
        case .viewThatFits(let axes, _): return "ViewThatFits(axes:\(axes.rawValue))"
        case .controlGroup: return "ControlGroup"
        case .tabView(let tabs, let style):
            return "TabView(tabs:\(tabs.count),style:\(style.rawValue))"
        case .button(let id, let role, _):
            return "Button(action:#\(id),role:\(role?.rawValue ?? "nil"))"
        case .label(let t, let i): return "Label(title:\(t.count),icon:\(i.count))"
        case .toggle(_, let v, let e): return "Toggle(isOn:\(v),event:#\(e.id))"
        case .slider(let v, let lo, let hi, let st, let e):
            return "Slider(value:\(v),in:\(lo)...\(hi),step:\(st.map { String($0) } ?? "nil"),event:#\(e.id))"
        case .stepper(_, let v, let lo, let hi, let st, let e):
            return "Stepper(value:\(v),in:\(lo.map { String($0) } ?? "nil")...\(hi.map { String($0) } ?? "nil"),step:\(st),event:#\(e.id))"
        case .textField(let p, let v, let e):
            return "TextField(placeholder:\"\(p)\",text:\"\(v)\",event:#\(e.id))"
        // Host-state controls.
        case .picker(_, let sel, let kind, let opts, let e):
            return "Picker(selection:\(sel.label),kind:\(kind.rawValue),options:\(opts.count),event:#\(e.id))"
        case .datePicker(_, let epoch, let comp, _, _, let e):
            return "DatePicker(epoch:\(epoch),components:\(comp),event:#\(e.id))"
        case .colorPicker(_, let c, let op, let e):
            return "ColorPicker(rgba(\(c.r),\(c.g),\(c.b),\(c.a)),opacity:\(op),event:#\(e.id))"
        case .navigationLink(let dest, let lbl):
            return "NavigationLink(destination:\(dest.count),label:\(lbl.count))"
        case .navigationStackPath(let path, _, let dests, let e):
            return "NavigationStack(path:\(path.count),destinations:\(dests.count),event:#\(e.id))"
        case .boundDisclosureGroup(let l, let exp, _, let e):
            return "DisclosureGroup(label:\(l.count),isExpanded:\(exp),event:#\(e.id))"
        case .boundSection(let h, let exp, _, let e):
            return "Section(header:\(h.count),isExpanded:\(exp),event:#\(e.id))"
        case .boundTabView(let sel, let kind, let tabs, let style, let e):
            return "TabView(selection:\(sel.label),kind:\(kind.rawValue),tabs:\(tabs.count),style:\(style.rawValue),event:#\(e.id))"
        case .editButton: return "EditButton"
        case .geometryReader(let id, let c): return "GeometryReader(#\(id),children:\(c.count))"
        case .canvas(let ops): return "Canvas(ops:\(ops.count))"
        case .opaque(let id, let label): return "Opaque(#\(id),\(label))"
        }
    }
}

extension Modifier {
    public var label: String {
        switch self {
        case .font(let f):
            var parts: [String] = []
            if let s = f.style { parts.append(s.rawValue) }
            if let sz = f.size { parts.append("size:\(sz)") }
            if let w = f.weight { parts.append(w.rawValue) }
            if let d = f.design { parts.append(d.rawValue) }
            return ".font(\(parts.joined(separator: ",")))"
        case .fontToken(let id): return ".fontToken(\(id))"
        case .foregroundColor(let c): return ".fg(\(c.label))"
        case .bold: return ".bold"
        case .italic: return ".italic"
        case .padding(let i):
            return ".padding(t:\(i.top),l:\(i.leading),b:\(i.bottom),tr:\(i.trailing))"
        case .frame(let w, let h, let a):
            return ".frame(w:\(w.map { String($0) } ?? "nil"),h:\(h.map { String($0) } ?? "nil"),a:\(a?.rawValue ?? "nil"))"
        case .background(let c): return ".bg(\(c.label))"
        case .cornerRadius(let r): return ".corner(\(r))"
        case .opacity(let o): return ".opacity(\(o))"
        case .lineLimit(let n): return ".lineLimit(\(n.map { String($0) } ?? "nil"))"
        case .multilineTextAlignment(let a): return ".mlAlign(\(a.rawValue))"
        case .onTapGesture(let e): return ".onTap(#\(e.id))"
        case .navigationTitle(let t): return ".navTitle(\"\(t)\")"
        case .flexFrame(let minW, let idealW, let maxW, let minH, let idealH, let maxH, let a):
            return ".flexFrame(minW:\(minW.label),idealW:\(idealW.label),maxW:\(maxW.label),"
                + "minH:\(minH.label),idealH:\(idealH.label),maxH:\(maxH.label),a:\(a?.rawValue ?? "nil"))"
        case .tint(let c): return ".tint(\(c.label))"
        case .clipShape(let s): return ".clipShape(\(s.label))"
        case .disabled(let b): return ".disabled(\(b))"
        case .fixedSize: return ".fixedSize"

        // Styling (IRShapeStyle vocabulary)
        case .foregroundStyle(let layers):
            return ".fgStyle(\(layers.map { $0.label }.joined(separator: "|")))"
        case .backgroundContent(let a, let c):
            return ".bgContent(a:\(a?.rawValue ?? "nil"),n:\(c.count))"
        case .backgroundStyle(let s, let shape):
            return ".bgStyle(\(s.label),in:\(shape?.label ?? "nil"))"
        case .tintStyle(let s): return ".tintStyle(\(s.label))"
        case .fill(let s, let eo): return ".fill(\(s.label),eo:\(eo))"
        case .stroke(let s, let st): return ".stroke(\(s.label),\(st.label))"
        case .strokeBorder(let s, let st): return ".strokeBorder(\(s.label),\(st.label))"
        case .border(let s, let w): return ".border(\(s.label),w:\(w))"
        case .overlayContent(let a, let c):
            return ".overlayContent(a:\(a?.rawValue ?? "nil"),n:\(c.count))"
        case .overlayStyle(let s, let shape): return ".overlayStyle(\(s.label),in:\(shape.label))"
        case .shadow(let c, let r, let x, let y):
            return ".shadow(c:\(c?.label ?? "nil"),r:\(r),x:\(x),y:\(y))"
        case .mask(let a, let c): return ".mask(a:\(a?.rawValue ?? "nil"),n:\(c.count))"

        // Layout
        case .offset(let x, let y): return ".offset(x:\(x),y:\(y))"
        case .position(let x, let y): return ".position(x:\(x),y:\(y))"
        case .aspectRatio(let r, let m):
            return ".aspectRatio(r:\(r.map { String($0) } ?? "nil"),\(m.rawValue))"
        case .clipped(let aa): return ".clipped(aa:\(aa))"
        case .fixedSizeAxis(let h, let v): return ".fixedSize(h:\(h),v:\(v))"
        case .layoutPriority(let p): return ".layoutPriority(\(p))"
        case .safeAreaInset(let e, let a, let sp, let c):
            return ".safeAreaInset(edge:\(e),a:\(a?.rawValue ?? "nil"),sp:\(sp.map { String($0) } ?? "nil"),n:\(c.count))"
        case .ignoresSafeArea(let regions, let edges):
            return ".ignoresSafeArea(regions:\(regions),edges:\(edges))"
        case .zIndex(let z): return ".zIndex(\(z))"
        case .containerRelativeFrame(let axes, let a):
            return ".containerRelativeFrame(axes:\(axes),a:\(a?.rawValue ?? "nil"))"

        // Transforms & visual effects
        case .rotationEffect(let d, let anchor):
            return ".rotationEffect(deg:\(d),anchor:\(anchor?.label ?? "nil"))"
        case .rotation3DEffect(let d, let x, let y, let z, let anchor, let az, let p):
            return ".rotation3D(deg:\(d),axis:(\(x),\(y),\(z)),anchor:\(anchor?.label ?? "nil"),anchorZ:\(az),persp:\(p))"
        case .scaleEffect(let x, let y, let anchor):
            return ".scaleEffect(x:\(x),y:\(y),anchor:\(anchor?.label ?? "nil"))"
        case .blur(let r, let o): return ".blur(r:\(r),opaque:\(o))"
        case .brightness(let v): return ".brightness(\(v))"
        case .contrast(let v): return ".contrast(\(v))"
        case .saturation(let v): return ".saturation(\(v))"
        case .grayscale(let v): return ".grayscale(\(v))"
        case .hueRotation(let d): return ".hueRotation(deg:\(d))"
        case .colorInvert: return ".colorInvert"
        case .blendMode(let m): return ".blendMode(\(m.rawValue))"

        // Text styling
        case .fontWeight(let w): return ".fontWeight(\(w?.rawValue ?? "nil"))"
        case .fontDesign(let d): return ".fontDesign(\(d?.rawValue ?? "nil"))"
        case .underline(let a, let c): return ".underline(\(a),c:\(c?.label ?? "nil"))"
        case .strikethrough(let a, let c): return ".strikethrough(\(a),c:\(c?.label ?? "nil"))"
        case .kerning(let v): return ".kerning(\(v))"
        case .tracking(let v): return ".tracking(\(v))"
        case .baselineOffset(let v): return ".baselineOffset(\(v))"
        case .lineSpacing(let v): return ".lineSpacing(\(v))"
        case .textCase(let c): return ".textCase(\(c ?? "nil"))"
        case .minimumScaleFactor(let v): return ".minScaleFactor(\(v))"
        case .truncationMode(let m): return ".truncationMode(\(m))"
        case .monospaced: return ".monospaced"
        case .monospacedDigit: return ".monospacedDigit"
        case .redacted(let r): return ".redacted(\(r))"
        case .unredacted: return ".unredacted"
        case .symbolRenderingMode(let m): return ".symbolRenderingMode(\(m))"
        case .symbolVariant(let v): return ".symbolVariant(\(v))"
        case .imageScale(let s): return ".imageScale(\(s))"
        case .dynamicTypeSize(let s): return ".dynamicTypeSize(\(s))"

        // Control config
        case .buttonStyle(let s): return ".buttonStyle(\(s.rawValue))"
        case .listStyle(let s): return ".listStyle(\(s.rawValue))"
        case .pickerStyle(let s): return ".pickerStyle(\(s))"
        case .toggleStyle(let s): return ".toggleStyle(\(s))"
        case .labelStyle(let s): return ".labelStyle(\(s))"
        case .gaugeStyle(let s): return ".gaugeStyle(\(s))"
        case .progressViewStyle(let s): return ".progressViewStyle(\(s))"
        case .menuStyle(let s): return ".menuStyle(\(s))"
        case .buttonBorderShape(let s): return ".buttonBorderShape(\(s))"
        case .controlSize(let s): return ".controlSize(\(s))"
        case .keyboardType(let s): return ".keyboardType(\(s))"
        case .textContentType(let s): return ".textContentType(\(s))"
        case .autocorrectionDisabled(let b): return ".autocorrectionDisabled(\(b))"
        case .textInputAutocapitalization(let s): return ".textInputAutocap(\(s))"
        case .submitLabel(let s): return ".submitLabel(\(s))"
        case .preferredColorScheme(let s): return ".preferredColorScheme(\(s ?? "nil"))"
        case .accentColor(let c): return ".accentColor(\(c?.label ?? "nil"))"

        // Gestures
        case .onLongPressGesture(let d, let e): return ".onLongPress(min:\(d),#\(e.id))"
        case .dragGesture(let d, let ch, let en):
            return ".drag(min:\(d),onChanged:\(ch.map { "#\($0.id)" } ?? "nil"),onEnded:\(en.map { "#\($0.id)" } ?? "nil"))"
        case .magnifyGesture(let e): return ".magnify(#\(e.id))"
        case .rotateGesture(let e): return ".rotate(#\(e.id))"

        // Lifecycle
        case .onAppear(let e): return ".onAppear(#\(e.id))"
        case .onDisappear(let e): return ".onDisappear(#\(e.id))"
        case .onChange(let k, let e): return ".onChange(key:\(k),#\(e.id))"
        case .task(let e, let id): return ".task(#\(e.id),id:\(id ?? "nil"))"
        case .onSubmit(let e): return ".onSubmit(#\(e.id))"
        case .onHover(let e): return ".onHover(#\(e.id))"
        case .sensoryFeedback(let kind, let key): return ".sensoryFeedback(\(kind),trigger:\(key))"

        // Animation
        case .animation(let a, let key): return ".animation(\(a?.label ?? "nil"),value:\(key))"
        case .transition(let t): return ".transition(\(t.label))"

        // Host-state — presentation / navigation / focus / list-editing
        case .sheet(let k, let p, let c, let e):
            return ".sheet(key:\(k),isPresented:\(p),content:\(c.count),#\(e.id))"
        case .sheetItem(let k, let p, let c, let e):
            return ".sheetItem(key:\(k),present:\(p),content:\(c.count),#\(e.id))"
        case .fullScreenCover(let k, let p, let c, let e):
            return ".fullScreenCover(key:\(k),isPresented:\(p),content:\(c.count),#\(e.id))"
        case .popover(let k, let p, let c, let e):
            return ".popover(key:\(k),isPresented:\(p),content:\(c.count),#\(e.id))"
        case .alert(let t, let k, let p, let a, let m, let e):
            return ".alert(\"\(t)\",key:\(k),isPresented:\(p),actions:\(a.count),message:\(m.count),#\(e.id))"
        case .confirmationDialog(let t, let tv, let k, let p, let a, let m, let e):
            return ".confirmationDialog(\"\(t)\",titleVisibility:\(tv),key:\(k),isPresented:\(p),actions:\(a.count),message:\(m.count),#\(e.id))"
        case .navigationDestinationBool(let k, let p, let d, let e):
            return ".navigationDestination(key:\(k),isPresented:\(p),destination:\(d.count),#\(e.id))"
        case .toolbar(let items): return ".toolbar(items:\(items.count))"
        case .navigationBarTitleDisplayMode(let m): return ".navBarTitleDisplayMode(\(m))"
        case .navigationBarBackButtonHidden(let h): return ".navBarBackButtonHidden(\(h))"
        case .searchable(let k, let q, let p, let e):
            return ".searchable(key:\(k),query:\"\(q)\",prompt:\(p ?? "nil"),#\(e.id))"
        case .focused(let k, let t, let f, let e):
            return ".focused(key:\(k),equals:\(t),isFocused:\(f),#\(e.id))"
        case .onDelete(let e): return ".onDelete(#\(e.id))"
        case .onMove(let e): return ".onMove(#\(e.id))"

        case .opaque(let s): return ".opaque(\(s))"
        }
    }
}

extension IRValue {
    /// A stable, readable label (used by `describe` for picker/tab selection tags).
    public var label: String {
        switch self {
        case .none: return "none"
        case .bool(let b): return "bool(\(b))"
        case .double(let d): return "double(\(d))"
        case .int(let i): return "int(\(i))"
        case .string(let s): return "string(\"\(s)\")"
        case .point(let x, let y): return "point(\(x),\(y))"
        case .array(let xs): return "array[" + xs.map { $0.label }.joined(separator: ",") + "]"
        }
    }
}

extension Optional where Wrapped == IRLength {
    /// A stable label for an optional flexible-frame bound.
    var label: String {
        switch self {
        case .none: return "nil"
        case .points(let x): return String(x)
        case .infinity: return "inf"
        }
    }
}

extension ColorRef {
    public var label: String {
        switch self {
        case .named(let n): return n
        case .rgba(let c): return "rgba(\(c.r),\(c.g),\(c.b),\(c.a))"
        case .hostToken(let id): return "token(\(id))"
        }
    }
}

extension ShapeKind {
    public var label: String {
        switch self {
        case .rectangle: return "rect"
        case .roundedRectangle(let r): return "rrect(\(r))"
        case .circle: return "circle"
        case .ellipse: return "ellipse"
        case .capsule: return "capsule"
        case .unevenRoundedRectangle(let tl, let tr, let bl, let br, let st):
            return "urrect(tl:\(tl),tr:\(tr),bl:\(bl),br:\(br),\(st.rawValue))"
        case .containerRelative: return "containerRelative"
        }
    }
}

extension IRUnitPoint {
    public var label: String {
        switch self {
        case .center: return "center"
        case .top: return "top"
        case .bottom: return "bottom"
        case .leading: return "leading"
        case .trailing: return "trailing"
        case .topLeading: return "topLeading"
        case .topTrailing: return "topTrailing"
        case .bottomLeading: return "bottomLeading"
        case .bottomTrailing: return "bottomTrailing"
        case .xy(let x, let y): return "(\(x),\(y))"
        }
    }
}

extension IRGradient {
    public var label: String {
        "grad[" + stops.map { "\($0.color.label)@\($0.location)" }.joined(separator: ",") + "]"
    }
}

extension IRStrokeStyle {
    public var label: String {
        "stroke(w:\(lineWidth),cap:\(cap),join:\(join),dash:\(dash.count))"
    }
}

extension IRShapeStyle {
    public var label: String {
        switch self {
        case .color(let c): return c.label
        case .linearGradient(let g, let s, let e):
            return "linear(\(g.label),\(s.label)->\(e.label))"
        case .radialGradient(let g, let c, let sr, let er):
            return "radial(\(g.label),c:\(c.label),r:\(sr)->\(er))"
        case .angularGradient(let g, let c, let sa, let ea):
            return "angular(\(g.label),c:\(c.label),a:\(sa)->\(ea))"
        case .material(let m): return "material(\(m.rawValue))"
        case .hierarchical(let l): return "hierarchical(\(l))"
        case .semantic(let s): return "semantic(\(s))"
        case .shadow(let s): return "shadow(r:\(s.radius))"
        }
    }
}

extension IRAnimation {
    public var label: String {
        var parts: [String] = [curve]
        if let d = duration { parts.append("dur:\(d)") }
        if let r = response { parts.append("resp:\(r)") }
        if let f = dampingFraction { parts.append("damp:\(f)") }
        if let d = delay { parts.append("delay:\(d)") }
        return "anim(\(parts.joined(separator: ",")))"
    }
}

extension IRTransition {
    public var label: String {
        switch self {
        case .identity: return "identity"
        case .opacity: return "opacity"
        case .scale(let s, let a): return "scale(\(s),\(a.label))"
        case .slide: return "slide"
        case .move(let e): return "move(\(e))"
        case .push(let e): return "push(\(e))"
        case .offset(let x, let y): return "offset(\(x),\(y))"
        case .blurReplace: return "blurReplace"
        case .combined(let ts): return "combined[" + ts.map { $0.label }.joined(separator: ",") + "]"
        case .asymmetric(let i, let r): return "asym(\(i.label),\(r.label))"
        }
    }
}
