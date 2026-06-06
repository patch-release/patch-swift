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
        case .image(let n): return "Image(systemName:\"\(n)\")"
        case .spacer(let m): return m.map { "Spacer(\($0))" } ?? "Spacer"
        case .divider: return "Divider"
        case .color(let c): return "Color(\(c.label))"
        case .shape(let s): return "Shape(\(s.label))"
        case .vstack(let a, let sp, _):
            return "VStack(align:\(a?.rawValue ?? "center"),spacing:\(sp.map { String($0) } ?? "nil"))"
        case .hstack(let a, let sp, _):
            return "HStack(align:\(a?.rawValue ?? "center"),spacing:\(sp.map { String($0) } ?? "nil"))"
        case .zstack(let a, _):
            return "ZStack(align:\(a?.rawValue ?? "center"))"
        case .group: return "Group"
        case .forEach: return "ForEach"
        case .button(let id, _): return "Button(action:#\(id))"
        case .toggle(_, let v, let e): return "Toggle(isOn:\(v),event:#\(e.id))"
        case .slider(let v, let lo, let hi, let st, let e):
            return "Slider(value:\(v),in:\(lo)...\(hi),step:\(st.map { String($0) } ?? "nil"),event:#\(e.id))"
        case .stepper(_, let v, let lo, let hi, let st, let e):
            return "Stepper(value:\(v),in:\(lo.map { String($0) } ?? "nil")...\(hi.map { String($0) } ?? "nil"),step:\(st),event:#\(e.id))"
        case .textField(let p, let v, let e):
            return "TextField(placeholder:\"\(p)\",text:\"\(v)\",event:#\(e.id))"
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
        case .opaque(let s): return ".opaque(\(s))"
        }
    }
}

extension ColorRef {
    public var label: String {
        switch self {
        case .named(let n): return n
        case .rgba(let c): return "rgba(\(c.r),\(c.g),\(c.b),\(c.a))"
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
        }
    }
}
