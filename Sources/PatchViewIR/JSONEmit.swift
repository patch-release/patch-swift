// JSONEmit.swift — a Foundation-FREE JSON serializer for the ViewNode tree.
// =========================================================================
// `JSONEncoder` needs Foundation, which the T0 *Embedded* Swift wasm tier does
// NOT have. To get a tiny (tens-of-KB) guest, the IR must serialize itself with
// no Foundation. This hand-rolled emitter produces JSON byte-for-byte
// compatible with the host's `JSONDecoder` reading `BodyEmission` — so the SAME
// host renderer decodes both the T2 (Foundation) and T0 (embedded) guests.
//
// It emits the exact shape Swift's synthesized `Codable` produces for these
// types (verified against the T2 round-trip in tests), namely:
//   * structs as objects with their stored-property keys,
//   * enums-with-associated-values as a single-key object whose key is the case
//     name and whose value is an object of the case's labeled payload
//     (Swift's default enum Codable representation),
//   * enums-without-payload as a string (their case name).
//
// This file is `Foundation`-free and compiles under Embedded Swift.

// MARK: - Non-finite-float wire tokens
//
// JSON has no representation for ±Infinity / NaN, so both the embedded emitter
// (this file) and the host's Foundation codec (`ViewNodeWire`) agree to carry a
// non-finite Double as one of these STRING tokens. They MUST match the strings
// passed to Foundation's `nonConformingFloat*Strategy.convert*String` so the two
// guest tiers round-trip identically. Foundation-free (Embedded-Swift-safe).
public enum JSONNonFinite {
    public static let positiveInfinity = "inf"
    public static let negativeInfinity = "-inf"
    public static let nan = "nan"
}

// MARK: - Tiny JSON string builder

struct JSONOut {
    var bytes: [UInt8] = []

    mutating func raw(_ s: StaticString) {
        s.withUTF8Buffer { buf in bytes.append(contentsOf: buf) }
    }
    mutating func raw(_ s: String) { bytes.append(contentsOf: Array(s.utf8)) }
    mutating func byte(_ b: UInt8) { bytes.append(b) }

    mutating func string(_ s: String) {
        byte(0x22) // "
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": raw("\\\"")
            case "\\": raw("\\\\")
            case "\n": raw("\\n")
            case "\r": raw("\\r")
            case "\t": raw("\\t")
            default:
                if scalar.value < 0x20 {
                    raw("\\u00")
                    let hi = hexDigit(UInt8(scalar.value >> 4))
                    let lo = hexDigit(UInt8(scalar.value & 0xF))
                    byte(hi); byte(lo)
                } else {
                    for u in String(scalar).utf8 { byte(u) }
                }
            }
        }
        byte(0x22)
    }

    mutating func number(_ d: Double) {
        // Non-finite doubles have NO valid JSON number form: `String(.infinity)`
        // is the bare token `inf` (and `nan` for NaN), which is invalid JSON the
        // host's `JSONDecoder` REJECTS — so a guest emitting `.frame(maxWidth:
        // .infinity)` (a ubiquitous SwiftUI idiom) would produce a tree the host
        // can't decode, collapsing the whole view to the error stub. Emit the
        // non-finite sentinel as a JSON STRING token instead; the host decodes it
        // via `nonConformingFloatDecodingStrategy.convertFromString` (see
        // `ViewNodeWire`), matching Foundation's own non-conforming-float strategy
        // so the T0 (embedded) and T2 (Foundation) guests round-trip identically.
        if !d.isFinite {
            if d.isNaN { string(JSONNonFinite.nan) }
            else if d > 0 { string(JSONNonFinite.positiveInfinity) }
            else { string(JSONNonFinite.negativeInfinity) }
            return
        }
        // Emit integers without a trailing ".0" only when exact; otherwise the
        // shortest round-trippable form. Embedded Swift has String(Double).
        if d == d.rounded() && abs(d) < 1e15 {
            raw(String(Int64(d)))
        } else {
            raw(String(d))
        }
    }
    mutating func number(_ i: Int) { raw(String(i)) }

    mutating func bool(_ b: Bool) { raw(b ? "true" : "false") }
    mutating func null() { raw("null") }

    private func hexDigit(_ v: UInt8) -> UInt8 {
        v < 10 ? (0x30 + v) : (0x61 + (v - 10))
    }
}

// MARK: - A minimal object/array writer with comma bookkeeping

extension JSONOut {
    mutating func object(_ build: (inout ObjectWriter) -> Void) {
        byte(0x7B) // {
        var w = ObjectWriter(out: self)
        build(&w)
        self = w.out
        byte(0x7D) // }
    }
    mutating func array(_ build: (inout ArrayWriter) -> Void) {
        byte(0x5B) // [
        var w = ArrayWriter(out: self)
        build(&w)
        self = w.out
        byte(0x5D) // ]
    }
}

struct ObjectWriter {
    var out: JSONOut
    var first = true
    mutating func key(_ k: StaticString) {
        if !first { out.byte(0x2C) } // ,
        first = false
        out.string(staticToString(k))
        out.byte(0x3A) // :
    }
    mutating func field(_ k: StaticString, _ build: (inout JSONOut) -> Void) {
        key(k); build(&out)
    }
}

struct ArrayWriter {
    var out: JSONOut
    var first = true
    mutating func element(_ build: (inout JSONOut) -> Void) {
        if !first { out.byte(0x2C) }
        first = false
        build(&out)
    }
}

private func staticToString(_ s: StaticString) -> String {
    s.withUTF8Buffer { String(decoding: $0, as: UTF8.self) }
}

// MARK: - ViewNode → JSON (matches the synthesized Codable shape)

public enum EmbeddedJSON {
    /// Encode a `BodyEmission` to JSON bytes WITHOUT Foundation.
    public static func encode(_ emission: BodyEmission) -> [UInt8] {
        var out = JSONOut()
        emitEmission(emission, into: &out)
        return out.bytes
    }

    /// Encode a `DispatchResult` (the `{state, tree, coverage?}` the interactive
    /// guest returns) WITHOUT Foundation. `state` is emitted as a JSON string.
    public static func encodeDispatch(_ r: DispatchResult) -> [UInt8] {
        var out = JSONOut()
        out.object { o in
            o.field("state") { $0.string(r.state) }
            o.field("tree") { emitNode(r.tree, into: &$0) }
            if let cov = r.coverage {
                o.field("coverage") { co in
                    co.object { c in
                        c.field("totalNodes") { $0.number(cov.totalNodes) }
                        c.field("opaqueNodes") { $0.number(cov.opaqueNodes) }
                        c.field("totalModifiers") { $0.number(cov.totalModifiers) }
                        c.field("opaqueModifiers") { $0.number(cov.opaqueModifiers) }
                    }
                }
            }
            if let v = r.schemaVersion { o.field("schemaVersion") { $0.number(v) } }
        }
        return out.bytes
    }

    static func emitEmission(_ e: BodyEmission, into out: inout JSONOut) {
        out.object { o in
            o.field("root") { emitNode(e.root, into: &$0) }
            if let cov = e.coverage {
                o.field("coverage") { co in
                    co.object { c in
                        c.field("totalNodes") { $0.number(cov.totalNodes) }
                        c.field("opaqueNodes") { $0.number(cov.opaqueNodes) }
                        c.field("totalModifiers") { $0.number(cov.totalModifiers) }
                        c.field("opaqueModifiers") { $0.number(cov.opaqueModifiers) }
                    }
                }
            }
            if let v = e.schemaVersion { o.field("schemaVersion") { $0.number(v) } }
        }
    }

    static func emitNode(_ node: ViewNode, into out: inout JSONOut) {
        out.object { o in
            o.field("kind") { emitKind(node.kind, into: &$0) }
            o.field("modifiers") { m in
                m.array { arr in
                    for mod in node.modifiers {
                        arr.element { emitModifier(mod, into: &$0) }
                    }
                }
            }
        }
    }

    // Swift encodes an enum case `case foo(A, B)` as {"foo":{"_0":…,"_1":…}}
    // and a labeled case `case foo(x: A)` as {"foo":{"x":…}}. We mirror that.
    static func emitKind(_ kind: NodeKind, into out: inout JSONOut) {
        switch kind {
        case .text(let s):
            singleAssoc(&out, "text") { $0.object { $0.field("_0") { $0.string(s) } } }
        case .styledText(let s, let verbatim, let markdown, let localized):
            singleAssoc(&out, "styledText") { o in
                o.object { ob in
                    ob.field("_0") { $0.string(s) }
                    ob.field("verbatim") { $0.bool(verbatim) }
                    ob.field("markdown") { $0.bool(markdown) }
                    ob.field("localized") { $0.bool(localized) }
                }
            }
        case .dateText(let epoch, let style):
            singleAssoc(&out, "dateText") { o in
                o.object { ob in
                    ob.field("epoch") { $0.number(epoch) }
                    ob.field("style") { $0.string(style.rawValue) }
                }
            }
        case .image(let name):
            singleAssoc(&out, "image") { $0.object { $0.field("systemName") { $0.string(name) } } }
        case .symbolImage(let name, let variableValue):
            singleAssoc(&out, "symbolImage") { o in
                o.object { ob in
                    ob.field("systemName") { $0.string(name) }
                    ob.field("variableValue") { v in if let variableValue { v.number(variableValue) } else { v.null() } }
                }
            }
        case .bundleImage(let name):
            singleAssoc(&out, "bundleImage") { $0.object { $0.field("name") { $0.string(name) } } }
        case .asyncImage(let url, let scale):
            singleAssoc(&out, "asyncImage") { o in
                o.object { ob in
                    ob.field("url") { $0.string(url) }
                    ob.field("scale") { v in if let scale { v.number(scale) } else { v.null() } }
                }
            }
        case .spacer(let m):
            singleAssoc(&out, "spacer") { o in
                o.object { ob in ob.field("minLength") { v in
                    if let m { v.number(m) } else { v.null() } } }
            }
        case .divider:
            stringCase(&out, "divider")
        case .color(let c):
            singleAssoc(&out, "color") { $0.object { $0.field("_0") { emitColor(c, into: &$0) } } }
        case .shape(let s):
            singleAssoc(&out, "shape") { $0.object { $0.field("_0") { emitShape(s, into: &$0) } } }
        case .path(let commands):
            singleAssoc(&out, "path") { o in
                o.object { ob in
                    ob.field("commands") { v in v.array { ar in for c in commands { ar.element { emitPathCommand(c, into: &$0) } } } }
                }
            }
        case .progressView:
            stringCase(&out, "progressView")
        case .determinateProgress(let value, let total, let label):
            singleAssoc(&out, "determinateProgress") { o in
                o.object { ob in
                    ob.field("value") { $0.number(value) }
                    ob.field("total") { $0.number(total) }
                    ob.field("label") { v in v.array { ar in for c in label { ar.element { emitNode(c, into: &$0) } } } }
                }
            }
        case .gauge(let data, let label):
            singleAssoc(&out, "gauge") { o in
                o.object { ob in
                    ob.field("data") { emitGauge(data, into: &$0) }
                    ob.field("label") { v in v.array { ar in for c in label { ar.element { emitNode(c, into: &$0) } } } }
                }
            }
        case .link(let destination, let label):
            singleAssoc(&out, "link") { o in
                o.object { ob in
                    ob.field("destination") { $0.string(destination) }
                    ob.field("label") { v in v.array { ar in for c in label { ar.element { emitNode(c, into: &$0) } } } }
                }
            }
        case .shareLink(let items, let label):
            singleAssoc(&out, "shareLink") { o in
                o.object { ob in
                    ob.field("items") { v in v.array { ar in for s in items { ar.element { $0.string(s) } } } }
                    ob.field("label") { v in v.array { ar in for c in label { ar.element { emitNode(c, into: &$0) } } } }
                }
            }
        case .vstack(let a, let sp, let ch):
            singleAssoc(&out, "vstack") { o in
                o.object { ob in
                    ob.field("alignment") { v in if let a { v.string(a.rawValue) } else { v.null() } }
                    ob.field("spacing") { v in if let sp { v.number(sp) } else { v.null() } }
                    ob.field("children") { v in v.array { ar in for c in ch { ar.element { emitNode(c, into: &$0) } } } }
                }
            }
        case .hstack(let a, let sp, let ch):
            singleAssoc(&out, "hstack") { o in
                o.object { ob in
                    ob.field("alignment") { v in if let a { v.string(a.rawValue) } else { v.null() } }
                    ob.field("spacing") { v in if let sp { v.number(sp) } else { v.null() } }
                    ob.field("children") { v in v.array { ar in for c in ch { ar.element { emitNode(c, into: &$0) } } } }
                }
            }
        case .zstack(let a, let ch):
            singleAssoc(&out, "zstack") { o in
                o.object { ob in
                    ob.field("alignment") { v in if let a { v.string(a.rawValue) } else { v.null() } }
                    ob.field("children") { v in v.array { ar in for c in ch { ar.element { emitNode(c, into: &$0) } } } }
                }
            }
        case .group(let ch):
            singleAssoc(&out, "group") { o in
                o.object { ob in ob.field("children") { v in v.array { ar in for c in ch { ar.element { emitNode(c, into: &$0) } } } } }
            }
        case .forEach(let ch):
            singleAssoc(&out, "forEach") { o in
                o.object { ob in ob.field("children") { v in v.array { ar in for c in ch { ar.element { emitNode(c, into: &$0) } } } } }
            }
        case .scrollView(let axis, let ch):
            singleAssoc(&out, "scrollView") { o in
                o.object { ob in
                    ob.field("axis") { $0.string(axis.rawValue) }
                    ob.field("children") { v in v.array { ar in for c in ch { ar.element { emitNode(c, into: &$0) } } } }
                }
            }
        case .list(let ch):
            singleAssoc(&out, "list") { o in
                o.object { ob in ob.field("children") { v in v.array { ar in for c in ch { ar.element { emitNode(c, into: &$0) } } } } }
            }
        case .section(let header, let footer, let content):
            singleAssoc(&out, "section") { o in
                o.object { ob in
                    ob.field("header") { v in v.array { ar in for c in header { ar.element { emitNode(c, into: &$0) } } } }
                    ob.field("footer") { v in v.array { ar in for c in footer { ar.element { emitNode(c, into: &$0) } } } }
                    ob.field("content") { v in v.array { ar in for c in content { ar.element { emitNode(c, into: &$0) } } } }
                }
            }
        case .form(let ch):
            singleAssoc(&out, "form") { o in
                o.object { ob in ob.field("children") { v in v.array { ar in for c in ch { ar.element { emitNode(c, into: &$0) } } } } }
            }
        case .navigationStack(let ch):
            singleAssoc(&out, "navigationStack") { o in
                o.object { ob in ob.field("children") { v in v.array { ar in for c in ch { ar.element { emitNode(c, into: &$0) } } } } }
            }
        case .lazyVStack(let a, let sp, let ch):
            singleAssoc(&out, "lazyVStack") { o in
                o.object { ob in
                    ob.field("alignment") { v in if let a { v.string(a.rawValue) } else { v.null() } }
                    ob.field("spacing") { v in if let sp { v.number(sp) } else { v.null() } }
                    ob.field("children") { v in v.array { ar in for c in ch { ar.element { emitNode(c, into: &$0) } } } }
                }
            }
        case .lazyHStack(let a, let sp, let ch):
            singleAssoc(&out, "lazyHStack") { o in
                o.object { ob in
                    ob.field("alignment") { v in if let a { v.string(a.rawValue) } else { v.null() } }
                    ob.field("spacing") { v in if let sp { v.number(sp) } else { v.null() } }
                    ob.field("children") { v in v.array { ar in for c in ch { ar.element { emitNode(c, into: &$0) } } } }
                }
            }
        case .lazyVGrid(let columns, let sp, let ch):
            singleAssoc(&out, "lazyVGrid") { o in
                o.object { ob in
                    ob.field("columns") { v in v.array { ar in for g in columns { ar.element { emitGridItem(g, into: &$0) } } } }
                    ob.field("spacing") { v in if let sp { v.number(sp) } else { v.null() } }
                    ob.field("children") { v in v.array { ar in for c in ch { ar.element { emitNode(c, into: &$0) } } } }
                }
            }
        case .lazyHGrid(let rows, let sp, let ch):
            singleAssoc(&out, "lazyHGrid") { o in
                o.object { ob in
                    ob.field("rows") { v in v.array { ar in for g in rows { ar.element { emitGridItem(g, into: &$0) } } } }
                    ob.field("spacing") { v in if let sp { v.number(sp) } else { v.null() } }
                    ob.field("children") { v in v.array { ar in for c in ch { ar.element { emitNode(c, into: &$0) } } } }
                }
            }
        case .grid(let a, let hSpacing, let vSpacing, let ch):
            singleAssoc(&out, "grid") { o in
                o.object { ob in
                    ob.field("alignment") { v in if let a { v.string(a.rawValue) } else { v.null() } }
                    ob.field("horizontalSpacing") { v in if let hSpacing { v.number(hSpacing) } else { v.null() } }
                    ob.field("verticalSpacing") { v in if let vSpacing { v.number(vSpacing) } else { v.null() } }
                    ob.field("children") { v in v.array { ar in for c in ch { ar.element { emitNode(c, into: &$0) } } } }
                }
            }
        case .gridRow(let a, let ch):
            singleAssoc(&out, "gridRow") { o in
                o.object { ob in
                    ob.field("alignment") { v in if let a { v.string(a.rawValue) } else { v.null() } }
                    ob.field("children") { v in v.array { ar in for c in ch { ar.element { emitNode(c, into: &$0) } } } }
                }
            }
        case .groupBox(let label, let ch):
            singleAssoc(&out, "groupBox") { o in
                o.object { ob in
                    ob.field("label") { v in v.array { ar in for c in label { ar.element { emitNode(c, into: &$0) } } } }
                    ob.field("children") { v in v.array { ar in for c in ch { ar.element { emitNode(c, into: &$0) } } } }
                }
            }
        case .disclosureGroup(let label, let ch):
            singleAssoc(&out, "disclosureGroup") { o in
                o.object { ob in
                    ob.field("label") { v in v.array { ar in for c in label { ar.element { emitNode(c, into: &$0) } } } }
                    ob.field("children") { v in v.array { ar in for c in ch { ar.element { emitNode(c, into: &$0) } } } }
                }
            }
        case .viewThatFits(let axes, let ch):
            singleAssoc(&out, "viewThatFits") { o in
                o.object { ob in
                    ob.field("axes") { $0.string(axes.rawValue) }
                    ob.field("children") { v in v.array { ar in for c in ch { ar.element { emitNode(c, into: &$0) } } } }
                }
            }
        case .controlGroup(let ch):
            singleAssoc(&out, "controlGroup") { o in
                o.object { ob in ob.field("children") { v in v.array { ar in for c in ch { ar.element { emitNode(c, into: &$0) } } } } }
            }
        case .tabView(let tabs, let style):
            singleAssoc(&out, "tabView") { o in
                o.object { ob in
                    ob.field("tabs") { v in v.array { ar in for t in tabs { ar.element { emitTab(t, into: &$0) } } } }
                    ob.field("style") { $0.string(style.rawValue) }
                }
            }
        case .button(let id, let role, let label):
            singleAssoc(&out, "button") { o in
                o.object { ob in
                    ob.field("actionID") { $0.string(id) }
                    ob.field("role") { v in if let role { v.string(role.rawValue) } else { v.null() } }
                    ob.field("label") { v in v.array { ar in for c in label { ar.element { emitNode(c, into: &$0) } } } }
                }
            }
        case .label(let title, let icon):
            singleAssoc(&out, "label") { o in
                o.object { ob in
                    ob.field("title") { v in v.array { ar in for c in title { ar.element { emitNode(c, into: &$0) } } } }
                    ob.field("icon") { v in v.array { ar in for c in icon { ar.element { emitNode(c, into: &$0) } } } }
                }
            }
        case .contextMenu(let content, let items):
            singleAssoc(&out, "contextMenu") { o in
                o.object { ob in
                    ob.field("content") { v in v.array { ar in for c in content { ar.element { emitNode(c, into: &$0) } } } }
                    ob.field("items") { v in v.array { ar in for c in items { ar.element { emitNode(c, into: &$0) } } } }
                }
            }
        case .menu(let label, let items):
            singleAssoc(&out, "menu") { o in
                o.object { ob in
                    ob.field("label") { v in v.array { ar in for c in label { ar.element { emitNode(c, into: &$0) } } } }
                    ob.field("items") { v in v.array { ar in for c in items { ar.element { emitNode(c, into: &$0) } } } }
                }
            }
        case .labeledContent(let label, let content):
            singleAssoc(&out, "labeledContent") { o in
                o.object { ob in
                    ob.field("label") { v in v.array { ar in for c in label { ar.element { emitNode(c, into: &$0) } } } }
                    ob.field("content") { v in v.array { ar in for c in content { ar.element { emitNode(c, into: &$0) } } } }
                }
            }
        case .secureField(let placeholder, let value, let event):
            singleAssoc(&out, "secureField") { o in
                o.object { ob in
                    ob.field("placeholder") { $0.string(placeholder) }
                    ob.field("value") { $0.string(value) }
                    ob.field("event") { emitEvent(event, into: &$0) }
                }
            }
        case .textEditor(let value, let event):
            singleAssoc(&out, "textEditor") { o in
                o.object { ob in
                    ob.field("value") { $0.string(value) }
                    ob.field("event") { emitEvent(event, into: &$0) }
                }
            }
        case .toggle(let label, let value, let event):
            singleAssoc(&out, "toggle") { o in
                o.object { ob in
                    ob.field("label") { v in v.array { ar in for c in label { ar.element { emitNode(c, into: &$0) } } } }
                    ob.field("value") { $0.bool(value) }
                    ob.field("event") { emitEvent(event, into: &$0) }
                }
            }
        case .slider(let value, let mn, let mx, let step, let event):
            singleAssoc(&out, "slider") { o in
                o.object { ob in
                    ob.field("value") { $0.number(value) }
                    ob.field("min") { $0.number(mn) }
                    ob.field("max") { $0.number(mx) }
                    ob.field("step") { v in if let step { v.number(step) } else { v.null() } }
                    ob.field("event") { emitEvent(event, into: &$0) }
                }
            }
        case .stepper(let label, let value, let mn, let mx, let step, let event):
            singleAssoc(&out, "stepper") { o in
                o.object { ob in
                    ob.field("label") { v in v.array { ar in for c in label { ar.element { emitNode(c, into: &$0) } } } }
                    ob.field("value") { $0.number(value) }
                    ob.field("min") { v in if let mn { v.number(mn) } else { v.null() } }
                    ob.field("max") { v in if let mx { v.number(mx) } else { v.null() } }
                    ob.field("step") { $0.number(step) }
                    ob.field("event") { emitEvent(event, into: &$0) }
                }
            }
        case .textField(let placeholder, let value, let event):
            singleAssoc(&out, "textField") { o in
                o.object { ob in
                    ob.field("placeholder") { $0.string(placeholder) }
                    ob.field("value") { $0.string(value) }
                    ob.field("event") { emitEvent(event, into: &$0) }
                }
            }
        case .picker(let label, let selection, let kind, let options, let event):
            singleAssoc(&out, "picker") { o in
                o.object { ob in
                    ob.field("label") { v in v.array { ar in for c in label { ar.element { emitNode(c, into: &$0) } } } }
                    ob.field("selection") { emitIRValue(selection, into: &$0) }
                    ob.field("kind") { $0.string(kind.rawValue) }
                    ob.field("options") { v in v.array { ar in for op in options { ar.element { emitPickerOption(op, into: &$0) } } } }
                    ob.field("event") { emitEvent(event, into: &$0) }
                }
            }
        case .datePicker(let label, let epoch, let components, let minE, let maxE, let event):
            singleAssoc(&out, "datePicker") { o in
                o.object { ob in
                    ob.field("label") { v in v.array { ar in for c in label { ar.element { emitNode(c, into: &$0) } } } }
                    ob.field("epoch") { $0.number(epoch) }
                    ob.field("components") { $0.string(components) }
                    ob.field("minEpoch") { v in if let minE { v.number(minE) } else { v.null() } }
                    ob.field("maxEpoch") { v in if let maxE { v.number(maxE) } else { v.null() } }
                    ob.field("event") { emitEvent(event, into: &$0) }
                }
            }
        case .colorPicker(let label, let color, let supportsOpacity, let event):
            singleAssoc(&out, "colorPicker") { o in
                o.object { ob in
                    ob.field("label") { v in v.array { ar in for c in label { ar.element { emitNode(c, into: &$0) } } } }
                    ob.field("color") { emitIRColorValue(color, into: &$0) }
                    ob.field("supportsOpacity") { $0.bool(supportsOpacity) }
                    ob.field("event") { emitEvent(event, into: &$0) }
                }
            }
        case .navigationLink(let destination, let label):
            singleAssoc(&out, "navigationLink") { o in
                o.object { ob in
                    ob.field("destination") { v in v.array { ar in for c in destination { ar.element { emitNode(c, into: &$0) } } } }
                    ob.field("label") { v in v.array { ar in for c in label { ar.element { emitNode(c, into: &$0) } } } }
                }
            }
        case .navigationStackPath(let path, let root, let destinations, let event):
            singleAssoc(&out, "navigationStackPath") { o in
                o.object { ob in
                    ob.field("path") { v in v.array { ar in for s in path { ar.element { $0.string(s) } } } }
                    ob.field("root") { v in v.array { ar in for c in root { ar.element { emitNode(c, into: &$0) } } } }
                    ob.field("destinations") { v in v.array { ar in for d in destinations { ar.element { emitNavDestination(d, into: &$0) } } } }
                    ob.field("event") { emitEvent(event, into: &$0) }
                }
            }
        case .boundDisclosureGroup(let label, let isExpanded, let content, let event):
            singleAssoc(&out, "boundDisclosureGroup") { o in
                o.object { ob in
                    ob.field("label") { v in v.array { ar in for c in label { ar.element { emitNode(c, into: &$0) } } } }
                    ob.field("isExpanded") { $0.bool(isExpanded) }
                    ob.field("content") { v in v.array { ar in for c in content { ar.element { emitNode(c, into: &$0) } } } }
                    ob.field("event") { emitEvent(event, into: &$0) }
                }
            }
        case .boundSection(let header, let isExpanded, let content, let event):
            singleAssoc(&out, "boundSection") { o in
                o.object { ob in
                    ob.field("header") { v in v.array { ar in for c in header { ar.element { emitNode(c, into: &$0) } } } }
                    ob.field("isExpanded") { $0.bool(isExpanded) }
                    ob.field("content") { v in v.array { ar in for c in content { ar.element { emitNode(c, into: &$0) } } } }
                    ob.field("event") { emitEvent(event, into: &$0) }
                }
            }
        case .boundTabView(let selection, let kind, let tabs, let style, let event):
            singleAssoc(&out, "boundTabView") { o in
                o.object { ob in
                    ob.field("selection") { emitIRValue(selection, into: &$0) }
                    ob.field("kind") { $0.string(kind.rawValue) }
                    ob.field("tabs") { v in v.array { ar in for t in tabs { ar.element { emitTab(t, into: &$0) } } } }
                    ob.field("style") { $0.string(style.rawValue) }
                    ob.field("event") { emitEvent(event, into: &$0) }
                }
            }
        case .editButton:
            stringCase(&out, "editButton")
        case .geometryReader(let id, let children):
            singleAssoc(&out, "geometryReader") { o in
                o.object { ob in
                    ob.field("id") { $0.string(id) }
                    ob.field("children") { v in v.array { ar in for c in children { ar.element { emitNode(c, into: &$0) } } } }
                }
            }
        case .canvas(let ops):
            singleAssoc(&out, "canvas") { o in
                o.object { ob in
                    ob.field("ops") { v in v.array { ar in for op in ops { ar.element { emitDrawOp(op, into: &$0) } } } }
                }
            }
        case .opaque(let id, let label):
            singleAssoc(&out, "opaque") { o in
                o.object { ob in
                    ob.field("id") { $0.string(id) }
                    ob.field("label") { $0.string(label) }
                }
            }
        }
    }

    /// `IRDrawOp` — Swift's synthesized enum Codable: a single-key object per case
    /// whose value is an object of the case's labeled payload.
    static func emitDrawOp(_ op: IRDrawOp, into out: inout JSONOut) {
        switch op {
        case .fillPath(let commands, let style):
            singleAssoc(&out, "fillPath") { o in
                o.object { ob in
                    ob.field("commands") { v in v.array { ar in for c in commands { ar.element { emitPathCommand(c, into: &$0) } } } }
                    ob.field("style") { emitShapeStyle(style, into: &$0) }
                }
            }
        case .strokePath(let commands, let style, let lineWidth):
            singleAssoc(&out, "strokePath") { o in
                o.object { ob in
                    ob.field("commands") { v in v.array { ar in for c in commands { ar.element { emitPathCommand(c, into: &$0) } } } }
                    ob.field("style") { emitShapeStyle(style, into: &$0) }
                    ob.field("lineWidth") { $0.number(lineWidth) }
                }
            }
        case .drawText(let text, let x, let y, let anchor):
            singleAssoc(&out, "drawText") { o in
                o.object { ob in
                    ob.field("text") { v in v.array { ar in for c in text { ar.element { emitNode(c, into: &$0) } } } }
                    ob.field("x") { $0.number(x) }
                    ob.field("y") { $0.number(y) }
                    ob.field("anchor") { $0.string(anchor) }
                }
            }
        }
    }

    static func emitModifier(_ m: Modifier, into out: inout JSONOut) {
        switch m {
        case .font(let f):
            singleAssoc(&out, "font") { $0.object { $0.field("_0") { emitFont(f, into: &$0) } } }
        case .fontToken(let id):
            // Matches the host's synthesized Codable shape `{"fontToken":{"_0":id}}`.
            singleAssoc(&out, "fontToken") { $0.object { $0.field("_0") { $0.string(id) } } }
        case .foregroundColor(let c):
            singleAssoc(&out, "foregroundColor") { $0.object { $0.field("_0") { emitColor(c, into: &$0) } } }
        case .bold: stringCase(&out, "bold")
        case .italic: stringCase(&out, "italic")
        case .padding(let i):
            singleAssoc(&out, "padding") { $0.object { $0.field("_0") { emitInsets(i, into: &$0) } } }
        case .frame(let w, let h, let a):
            singleAssoc(&out, "frame") { o in
                o.object { ob in
                    ob.field("width") { v in if let w { v.number(w) } else { v.null() } }
                    ob.field("height") { v in if let h { v.number(h) } else { v.null() } }
                    ob.field("alignment") { v in if let a { v.string(a.rawValue) } else { v.null() } }
                }
            }
        case .background(let c):
            singleAssoc(&out, "background") { $0.object { $0.field("_0") { emitColor(c, into: &$0) } } }
        case .cornerRadius(let r):
            singleAssoc(&out, "cornerRadius") { $0.object { $0.field("_0") { $0.number(r) } } }
        case .opacity(let o):
            singleAssoc(&out, "opacity") { $0.object { $0.field("_0") { $0.number(o) } } }
        case .lineLimit(let n):
            singleAssoc(&out, "lineLimit") { o in
                o.object { ob in ob.field("_0") { v in if let n { v.number(n) } else { v.null() } } }
            }
        case .multilineTextAlignment(let a):
            singleAssoc(&out, "multilineTextAlignment") { $0.object { $0.field("_0") { $0.string(a.rawValue) } } }
        case .onTapGesture(let e):
            singleAssoc(&out, "onTapGesture") { $0.object { $0.field("_0") { emitEvent(e, into: &$0) } } }
        case .navigationTitle(let t):
            singleAssoc(&out, "navigationTitle") { $0.object { $0.field("_0") { $0.string(t) } } }
        case .flexFrame(let minW, let idealW, let maxW, let minH, let idealH, let maxH, let a):
            singleAssoc(&out, "flexFrame") { o in
                o.object { ob in
                    ob.field("minWidth") { v in if let minW { emitLength(minW, into: &v) } else { v.null() } }
                    ob.field("idealWidth") { v in if let idealW { emitLength(idealW, into: &v) } else { v.null() } }
                    ob.field("maxWidth") { v in if let maxW { emitLength(maxW, into: &v) } else { v.null() } }
                    ob.field("minHeight") { v in if let minH { emitLength(minH, into: &v) } else { v.null() } }
                    ob.field("idealHeight") { v in if let idealH { emitLength(idealH, into: &v) } else { v.null() } }
                    ob.field("maxHeight") { v in if let maxH { emitLength(maxH, into: &v) } else { v.null() } }
                    ob.field("alignment") { v in if let a { v.string(a.rawValue) } else { v.null() } }
                }
            }
        case .tint(let c):
            singleAssoc(&out, "tint") { $0.object { $0.field("_0") { emitColor(c, into: &$0) } } }
        case .clipShape(let s):
            singleAssoc(&out, "clipShape") { $0.object { $0.field("_0") { emitShape(s, into: &$0) } } }
        case .trim(let from, let to):
            singleAssoc(&out, "trim") { o in
                o.object { ob in ob.field("from") { $0.number(from) }; ob.field("to") { $0.number(to) } }
            }
        case .disabled(let b):
            singleAssoc(&out, "disabled") { $0.object { $0.field("_0") { $0.bool(b) } } }
        case .fixedSize:
            stringCase(&out, "fixedSize")

        // MARK: Styling (IRShapeStyle vocabulary)
        case .foregroundStyle(let layers):
            singleAssoc(&out, "foregroundStyle") { o in
                o.object { ob in ob.field("_0") { v in v.array { ar in
                    for s in layers { ar.element { emitShapeStyle(s, into: &$0) } } } } }
            }
        case .backgroundContent(let a, let c):
            singleAssoc(&out, "backgroundContent") { o in
                o.object { ob in
                    ob.field("alignment") { v in if let a { v.string(a.rawValue) } else { v.null() } }
                    ob.field("content") { v in v.array { ar in for n in c { ar.element { emitNode(n, into: &$0) } } } }
                }
            }
        case .backgroundStyle(let s, let shape):
            singleAssoc(&out, "backgroundStyle") { o in
                o.object { ob in
                    ob.field("_0") { emitShapeStyle(s, into: &$0) }
                    ob.field("in") { v in if let shape { emitShape(shape, into: &v) } else { v.null() } }
                }
            }
        case .tintStyle(let s):
            singleAssoc(&out, "tintStyle") { $0.object { $0.field("_0") { emitShapeStyle(s, into: &$0) } } }
        case .fill(let s, let eo):
            singleAssoc(&out, "fill") { o in
                o.object { ob in
                    ob.field("_0") { emitShapeStyle(s, into: &$0) }
                    ob.field("eoFill") { $0.bool(eo) }
                }
            }
        case .stroke(let s, let st):
            singleAssoc(&out, "stroke") { o in
                o.object { ob in
                    ob.field("_0") { emitShapeStyle(s, into: &$0) }
                    ob.field("_1") { emitStrokeStyle(st, into: &$0) }
                }
            }
        case .strokeBorder(let s, let st):
            singleAssoc(&out, "strokeBorder") { o in
                o.object { ob in
                    ob.field("_0") { emitShapeStyle(s, into: &$0) }
                    ob.field("_1") { emitStrokeStyle(st, into: &$0) }
                }
            }
        case .border(let s, let w):
            singleAssoc(&out, "border") { o in
                o.object { ob in
                    ob.field("_0") { emitShapeStyle(s, into: &$0) }
                    ob.field("width") { $0.number(w) }
                }
            }
        case .overlayContent(let a, let c):
            singleAssoc(&out, "overlayContent") { o in
                o.object { ob in
                    ob.field("alignment") { v in if let a { v.string(a.rawValue) } else { v.null() } }
                    ob.field("content") { v in v.array { ar in for n in c { ar.element { emitNode(n, into: &$0) } } } }
                }
            }
        case .overlayStyle(let s, let shape):
            singleAssoc(&out, "overlayStyle") { o in
                o.object { ob in
                    ob.field("_0") { emitShapeStyle(s, into: &$0) }
                    ob.field("in") { emitShape(shape, into: &$0) }
                }
            }
        case .shadow(let c, let r, let x, let y):
            singleAssoc(&out, "shadow") { o in
                o.object { ob in
                    ob.field("color") { v in if let c { emitColor(c, into: &v) } else { v.null() } }
                    ob.field("radius") { $0.number(r) }
                    ob.field("x") { $0.number(x) }
                    ob.field("y") { $0.number(y) }
                }
            }
        case .mask(let a, let c):
            singleAssoc(&out, "mask") { o in
                o.object { ob in
                    ob.field("alignment") { v in if let a { v.string(a.rawValue) } else { v.null() } }
                    ob.field("content") { v in v.array { ar in for n in c { ar.element { emitNode(n, into: &$0) } } } }
                }
            }

        // MARK: Layout
        case .offset(let x, let y):
            singleAssoc(&out, "offset") { o in
                o.object { ob in ob.field("x") { $0.number(x) }; ob.field("y") { $0.number(y) } }
            }
        case .position(let x, let y):
            singleAssoc(&out, "position") { o in
                o.object { ob in ob.field("x") { $0.number(x) }; ob.field("y") { $0.number(y) } }
            }
        case .aspectRatio(let r, let m):
            singleAssoc(&out, "aspectRatio") { o in
                o.object { ob in
                    ob.field("ratio") { v in if let r { v.number(r) } else { v.null() } }
                    ob.field("_1") { $0.string(m.rawValue) }
                }
            }
        case .clipped(let aa):
            singleAssoc(&out, "clipped") { $0.object { $0.field("antialiased") { $0.bool(aa) } } }
        case .fixedSizeAxis(let h, let v):
            singleAssoc(&out, "fixedSizeAxis") { o in
                o.object { ob in ob.field("horizontal") { $0.bool(h) }; ob.field("vertical") { $0.bool(v) } }
            }
        case .layoutPriority(let p):
            singleAssoc(&out, "layoutPriority") { $0.object { $0.field("_0") { $0.number(p) } } }
        case .safeAreaInset(let e, let a, let sp, let c):
            singleAssoc(&out, "safeAreaInset") { o in
                o.object { ob in
                    ob.field("edge") { $0.string(e) }
                    ob.field("alignment") { v in if let a { v.string(a.rawValue) } else { v.null() } }
                    ob.field("spacing") { v in if let sp { v.number(sp) } else { v.null() } }
                    ob.field("content") { v in v.array { ar in for n in c { ar.element { emitNode(n, into: &$0) } } } }
                }
            }
        case .ignoresSafeArea(let regions, let edges):
            singleAssoc(&out, "ignoresSafeArea") { o in
                o.object { ob in ob.field("regions") { $0.string(regions) }; ob.field("edges") { $0.string(edges) } }
            }
        case .zIndex(let z):
            singleAssoc(&out, "zIndex") { $0.object { $0.field("_0") { $0.number(z) } } }
        case .containerRelativeFrame(let axes, let a):
            singleAssoc(&out, "containerRelativeFrame") { o in
                o.object { ob in
                    ob.field("axes") { $0.string(axes) }
                    ob.field("alignment") { v in if let a { v.string(a.rawValue) } else { v.null() } }
                }
            }
        case .allowsHitTesting(let b):
            singleAssoc(&out, "allowsHitTesting") { $0.object { $0.field("_0") { $0.bool(b) } } }
        case .scrollClipDisabled(let b):
            singleAssoc(&out, "scrollClipDisabled") { $0.object { $0.field("_0") { $0.bool(b) } } }
        case .scrollContentBackground(let vis):
            singleAssoc(&out, "scrollContentBackground") { $0.object { $0.field("_0") { $0.string(vis) } } }
        case .listRowSeparator(let vis, let edges):
            singleAssoc(&out, "listRowSeparator") { o in
                o.object { ob in ob.field("_0") { $0.string(vis) }; ob.field("edges") { $0.string(edges) } }
            }
        case .listRowBackground(let content):
            singleAssoc(&out, "listRowBackground") { o in
                o.object { ob in ob.field("_0") { v in v.array { ar in for n in content { ar.element { emitNode(n, into: &$0) } } } } }
            }
        case .listRowInsets(let i):
            singleAssoc(&out, "listRowInsets") { $0.object { $0.field("_0") { emitInsets(i, into: &$0) } } }
        case .listSectionSeparator(let vis, let edges):
            singleAssoc(&out, "listSectionSeparator") { o in
                o.object { ob in ob.field("_0") { $0.string(vis) }; ob.field("edges") { $0.string(edges) } }
            }

        // MARK: Transforms & visual effects
        case .rotationEffect(let d, let anchor):
            singleAssoc(&out, "rotationEffect") { o in
                o.object { ob in
                    ob.field("degrees") { $0.number(d) }
                    ob.field("anchor") { v in if let anchor { emitUnitPoint(anchor, into: &v) } else { v.null() } }
                }
            }
        case .rotation3DEffect(let d, let x, let y, let z, let anchor, let az, let p):
            singleAssoc(&out, "rotation3DEffect") { o in
                o.object { ob in
                    ob.field("degrees") { $0.number(d) }
                    ob.field("x") { $0.number(x) }
                    ob.field("y") { $0.number(y) }
                    ob.field("z") { $0.number(z) }
                    ob.field("anchor") { v in if let anchor { emitUnitPoint(anchor, into: &v) } else { v.null() } }
                    ob.field("anchorZ") { $0.number(az) }
                    ob.field("perspective") { $0.number(p) }
                }
            }
        case .scaleEffect(let x, let y, let anchor):
            singleAssoc(&out, "scaleEffect") { o in
                o.object { ob in
                    ob.field("x") { $0.number(x) }
                    ob.field("y") { $0.number(y) }
                    ob.field("anchor") { v in if let anchor { emitUnitPoint(anchor, into: &v) } else { v.null() } }
                }
            }
        case .blur(let r, let o):
            singleAssoc(&out, "blur") { ob0 in
                ob0.object { ob in ob.field("radius") { $0.number(r) }; ob.field("opaque") { $0.bool(o) } }
            }
        case .brightness(let v):
            singleAssoc(&out, "brightness") { $0.object { $0.field("_0") { $0.number(v) } } }
        case .contrast(let v):
            singleAssoc(&out, "contrast") { $0.object { $0.field("_0") { $0.number(v) } } }
        case .saturation(let v):
            singleAssoc(&out, "saturation") { $0.object { $0.field("_0") { $0.number(v) } } }
        case .grayscale(let v):
            singleAssoc(&out, "grayscale") { $0.object { $0.field("_0") { $0.number(v) } } }
        case .hueRotation(let d):
            singleAssoc(&out, "hueRotation") { $0.object { $0.field("degrees") { $0.number(d) } } }
        case .colorInvert:
            stringCase(&out, "colorInvert")
        case .blendMode(let m):
            singleAssoc(&out, "blendMode") { $0.object { $0.field("_0") { $0.string(m.rawValue) } } }

        // MARK: Text styling
        case .fontWeight(let w):
            singleAssoc(&out, "fontWeight") { o in
                o.object { ob in ob.field("_0") { v in if let w { v.string(w.rawValue) } else { v.null() } } }
            }
        case .fontDesign(let d):
            singleAssoc(&out, "fontDesign") { o in
                o.object { ob in ob.field("_0") { v in if let d { v.string(d.rawValue) } else { v.null() } } }
            }
        case .underline(let a, let c):
            singleAssoc(&out, "underline") { o in
                o.object { ob in
                    ob.field("active") { $0.bool(a) }
                    ob.field("color") { v in if let c { emitColor(c, into: &v) } else { v.null() } }
                }
            }
        case .strikethrough(let a, let c):
            singleAssoc(&out, "strikethrough") { o in
                o.object { ob in
                    ob.field("active") { $0.bool(a) }
                    ob.field("color") { v in if let c { emitColor(c, into: &v) } else { v.null() } }
                }
            }
        case .kerning(let v):
            singleAssoc(&out, "kerning") { $0.object { $0.field("_0") { $0.number(v) } } }
        case .tracking(let v):
            singleAssoc(&out, "tracking") { $0.object { $0.field("_0") { $0.number(v) } } }
        case .baselineOffset(let v):
            singleAssoc(&out, "baselineOffset") { $0.object { $0.field("_0") { $0.number(v) } } }
        case .lineSpacing(let v):
            singleAssoc(&out, "lineSpacing") { $0.object { $0.field("_0") { $0.number(v) } } }
        case .textCase(let c):
            singleAssoc(&out, "textCase") { o in
                o.object { ob in ob.field("_0") { v in if let c { v.string(c) } else { v.null() } } }
            }
        case .minimumScaleFactor(let v):
            singleAssoc(&out, "minimumScaleFactor") { $0.object { $0.field("_0") { $0.number(v) } } }
        case .truncationMode(let m):
            singleAssoc(&out, "truncationMode") { $0.object { $0.field("_0") { $0.string(m) } } }
        case .monospaced:
            stringCase(&out, "monospaced")
        case .monospacedDigit:
            stringCase(&out, "monospacedDigit")
        case .redacted(let r):
            singleAssoc(&out, "redacted") { $0.object { $0.field("reason") { $0.string(r) } } }
        case .unredacted:
            stringCase(&out, "unredacted")
        case .symbolRenderingMode(let m):
            singleAssoc(&out, "symbolRenderingMode") { $0.object { $0.field("_0") { $0.string(m) } } }
        case .symbolVariant(let v):
            singleAssoc(&out, "symbolVariant") { $0.object { $0.field("_0") { $0.string(v) } } }
        case .imageScale(let s):
            singleAssoc(&out, "imageScale") { $0.object { $0.field("_0") { $0.string(s) } } }
        case .dynamicTypeSize(let s):
            singleAssoc(&out, "dynamicTypeSize") { $0.object { $0.field("_0") { $0.string(s) } } }

        // MARK: Control config (built-in style enums)
        case .buttonStyle(let s):
            singleAssoc(&out, "buttonStyle") { $0.object { $0.field("_0") { $0.string(s.rawValue) } } }
        case .listStyle(let s):
            singleAssoc(&out, "listStyle") { $0.object { $0.field("_0") { $0.string(s.rawValue) } } }
        case .pickerStyle(let s):
            singleAssoc(&out, "pickerStyle") { $0.object { $0.field("_0") { $0.string(s) } } }
        case .toggleStyle(let s):
            singleAssoc(&out, "toggleStyle") { $0.object { $0.field("_0") { $0.string(s) } } }
        case .labelStyle(let s):
            singleAssoc(&out, "labelStyle") { $0.object { $0.field("_0") { $0.string(s) } } }
        case .gaugeStyle(let s):
            singleAssoc(&out, "gaugeStyle") { $0.object { $0.field("_0") { $0.string(s) } } }
        case .progressViewStyle(let s):
            singleAssoc(&out, "progressViewStyle") { $0.object { $0.field("_0") { $0.string(s) } } }
        case .menuStyle(let s):
            singleAssoc(&out, "menuStyle") { $0.object { $0.field("_0") { $0.string(s) } } }
        case .buttonBorderShape(let s):
            singleAssoc(&out, "buttonBorderShape") { $0.object { $0.field("_0") { $0.string(s) } } }
        case .controlSize(let s):
            singleAssoc(&out, "controlSize") { $0.object { $0.field("_0") { $0.string(s) } } }
        case .tabViewStyle(let s):
            singleAssoc(&out, "tabViewStyle") { $0.object { $0.field("_0") { $0.string(s) } } }
        case .indexViewStyle(let s):
            singleAssoc(&out, "indexViewStyle") { $0.object { $0.field("_0") { $0.string(s) } } }
        case .keyboardType(let s):
            singleAssoc(&out, "keyboardType") { $0.object { $0.field("_0") { $0.string(s) } } }
        case .textContentType(let s):
            singleAssoc(&out, "textContentType") { $0.object { $0.field("_0") { $0.string(s) } } }
        case .autocorrectionDisabled(let b):
            singleAssoc(&out, "autocorrectionDisabled") { $0.object { $0.field("_0") { $0.bool(b) } } }
        case .textInputAutocapitalization(let s):
            singleAssoc(&out, "textInputAutocapitalization") { $0.object { $0.field("_0") { $0.string(s) } } }
        case .submitLabel(let s):
            singleAssoc(&out, "submitLabel") { $0.object { $0.field("_0") { $0.string(s) } } }
        case .preferredColorScheme(let s):
            singleAssoc(&out, "preferredColorScheme") { o in
                o.object { ob in ob.field("_0") { v in if let s { v.string(s) } else { v.null() } } }
            }
        case .accentColor(let c):
            singleAssoc(&out, "accentColor") { o in
                o.object { ob in ob.field("_0") { v in if let c { emitColor(c, into: &v) } else { v.null() } } }
            }

        // MARK: Gestures
        case .onLongPressGesture(let d, let e):
            singleAssoc(&out, "onLongPressGesture") { o in
                o.object { ob in
                    ob.field("minimumDuration") { $0.number(d) }
                    ob.field("_1") { emitEvent(e, into: &$0) }
                }
            }
        case .dragGesture(let d, let ch, let en):
            singleAssoc(&out, "dragGesture") { o in
                o.object { ob in
                    ob.field("minDistance") { $0.number(d) }
                    ob.field("onChanged") { v in if let ch { emitEvent(ch, into: &v) } else { v.null() } }
                    ob.field("onEnded") { v in if let en { emitEvent(en, into: &v) } else { v.null() } }
                }
            }
        case .magnifyGesture(let e):
            singleAssoc(&out, "magnifyGesture") { $0.object { $0.field("_0") { emitEvent(e, into: &$0) } } }
        case .rotateGesture(let e):
            singleAssoc(&out, "rotateGesture") { $0.object { $0.field("_0") { emitEvent(e, into: &$0) } } }

        // MARK: Lifecycle
        case .onAppear(let e):
            singleAssoc(&out, "onAppear") { $0.object { $0.field("_0") { emitEvent(e, into: &$0) } } }
        case .onDisappear(let e):
            singleAssoc(&out, "onDisappear") { $0.object { $0.field("_0") { emitEvent(e, into: &$0) } } }
        case .onChange(let k, let e):
            singleAssoc(&out, "onChange") { o in
                o.object { ob in
                    ob.field("valueKey") { $0.string(k) }
                    ob.field("_1") { emitEvent(e, into: &$0) }
                }
            }
        case .task(let e, let id):
            singleAssoc(&out, "task") { o in
                o.object { ob in
                    ob.field("_0") { emitEvent(e, into: &$0) }
                    ob.field("id") { v in if let id { v.string(id) } else { v.null() } }
                }
            }
        case .onSubmit(let e):
            singleAssoc(&out, "onSubmit") { $0.object { $0.field("_0") { emitEvent(e, into: &$0) } } }
        case .onHover(let e):
            singleAssoc(&out, "onHover") { $0.object { $0.field("_0") { emitEvent(e, into: &$0) } } }
        case .sensoryFeedback(let kind, let key):
            singleAssoc(&out, "sensoryFeedback") { o in
                o.object { ob in ob.field("kind") { $0.string(kind) }; ob.field("triggerKey") { $0.string(key) } }
            }

        // MARK: Animation
        case .animation(let a, let key):
            singleAssoc(&out, "animation") { o in
                o.object { ob in
                    ob.field("_0") { v in if let a { emitAnimation(a, into: &v) } else { v.null() } }
                    ob.field("valueKey") { $0.string(key) }
                }
            }
        case .transition(let t):
            singleAssoc(&out, "transition") { $0.object { $0.field("_0") { emitTransition(t, into: &$0) } } }

        // MARK: Host-state — presentation / navigation / focus / list-editing
        case .sheet(let key, let isPresented, let content, let event):
            singleAssoc(&out, "sheet") { o in
                o.object { ob in
                    ob.field("presentedKey") { $0.string(key) }
                    ob.field("isPresented") { $0.bool(isPresented) }
                    ob.field("content") { v in v.array { ar in for n in content { ar.element { emitNode(n, into: &$0) } } } }
                    ob.field("event") { emitEvent(event, into: &$0) }
                }
            }
        case .sheetItem(let key, let present, let content, let event):
            singleAssoc(&out, "sheetItem") { o in
                o.object { ob in
                    ob.field("itemKey") { $0.string(key) }
                    ob.field("itemPresent") { $0.bool(present) }
                    ob.field("content") { v in v.array { ar in for n in content { ar.element { emitNode(n, into: &$0) } } } }
                    ob.field("event") { emitEvent(event, into: &$0) }
                }
            }
        case .fullScreenCover(let key, let isPresented, let content, let event):
            singleAssoc(&out, "fullScreenCover") { o in
                o.object { ob in
                    ob.field("presentedKey") { $0.string(key) }
                    ob.field("isPresented") { $0.bool(isPresented) }
                    ob.field("content") { v in v.array { ar in for n in content { ar.element { emitNode(n, into: &$0) } } } }
                    ob.field("event") { emitEvent(event, into: &$0) }
                }
            }
        case .popover(let key, let isPresented, let content, let event):
            singleAssoc(&out, "popover") { o in
                o.object { ob in
                    ob.field("presentedKey") { $0.string(key) }
                    ob.field("isPresented") { $0.bool(isPresented) }
                    ob.field("content") { v in v.array { ar in for n in content { ar.element { emitNode(n, into: &$0) } } } }
                    ob.field("event") { emitEvent(event, into: &$0) }
                }
            }
        case .alert(let title, let key, let isPresented, let actions, let message, let event):
            singleAssoc(&out, "alert") { o in
                o.object { ob in
                    ob.field("title") { $0.string(title) }
                    ob.field("presentedKey") { $0.string(key) }
                    ob.field("isPresented") { $0.bool(isPresented) }
                    ob.field("actions") { v in v.array { ar in for n in actions { ar.element { emitNode(n, into: &$0) } } } }
                    ob.field("message") { v in v.array { ar in for n in message { ar.element { emitNode(n, into: &$0) } } } }
                    ob.field("event") { emitEvent(event, into: &$0) }
                }
            }
        case .confirmationDialog(let title, let tv, let key, let isPresented, let actions, let message, let event):
            singleAssoc(&out, "confirmationDialog") { o in
                o.object { ob in
                    ob.field("title") { $0.string(title) }
                    ob.field("titleVisibility") { $0.string(tv) }
                    ob.field("presentedKey") { $0.string(key) }
                    ob.field("isPresented") { $0.bool(isPresented) }
                    ob.field("actions") { v in v.array { ar in for n in actions { ar.element { emitNode(n, into: &$0) } } } }
                    ob.field("message") { v in v.array { ar in for n in message { ar.element { emitNode(n, into: &$0) } } } }
                    ob.field("event") { emitEvent(event, into: &$0) }
                }
            }
        case .navigationDestinationBool(let key, let isPresented, let destination, let event):
            singleAssoc(&out, "navigationDestinationBool") { o in
                o.object { ob in
                    ob.field("presentedKey") { $0.string(key) }
                    ob.field("isPresented") { $0.bool(isPresented) }
                    ob.field("destination") { v in v.array { ar in for n in destination { ar.element { emitNode(n, into: &$0) } } } }
                    ob.field("event") { emitEvent(event, into: &$0) }
                }
            }
        case .toolbar(let items):
            singleAssoc(&out, "toolbar") { o in
                o.object { ob in ob.field("items") { v in v.array { ar in for it in items { ar.element { emitToolbarItem(it, into: &$0) } } } } }
            }
        case .navigationBarTitleDisplayMode(let m):
            singleAssoc(&out, "navigationBarTitleDisplayMode") { $0.object { $0.field("_0") { $0.string(m) } } }
        case .navigationBarBackButtonHidden(let h):
            singleAssoc(&out, "navigationBarBackButtonHidden") { $0.object { $0.field("_0") { $0.bool(h) } } }
        case .presentationDetents(let detents):
            singleAssoc(&out, "presentationDetents") { o in
                o.object { ob in ob.field("_0") { v in v.array { ar in for d in detents { ar.element { $0.string(d) } } } } }
            }
        case .presentationDragIndicator(let vis):
            singleAssoc(&out, "presentationDragIndicator") { $0.object { $0.field("_0") { $0.string(vis) } } }
        case .navigationBarTitle(let title, let mode):
            singleAssoc(&out, "navigationBarTitle") { o in
                o.object { ob in ob.field("_0") { $0.string(title) }; ob.field("displayMode") { $0.string(mode) } }
            }
        case .navigationViewStyle(let s):
            singleAssoc(&out, "navigationViewStyle") { $0.object { $0.field("_0") { $0.string(s) } } }
        case .environmentValue(let key, let value):
            singleAssoc(&out, "environmentValue") { o in
                o.object { ob in ob.field("key") { $0.string(key) }; ob.field("value") { $0.string(value) } }
            }
        case .accessibilityLabel(let s):
            singleAssoc(&out, "accessibilityLabel") { $0.object { $0.field("_0") { $0.string(s) } } }
        case .accessibilityHint(let s):
            singleAssoc(&out, "accessibilityHint") { $0.object { $0.field("_0") { $0.string(s) } } }
        case .accessibilityValue(let s):
            singleAssoc(&out, "accessibilityValue") { $0.object { $0.field("_0") { $0.string(s) } } }
        case .accessibilityHidden(let b):
            singleAssoc(&out, "accessibilityHidden") { $0.object { $0.field("_0") { $0.bool(b) } } }
        case .accessibilityAddTraits(let s):
            singleAssoc(&out, "accessibilityAddTraits") { $0.object { $0.field("_0") { $0.string(s) } } }
        case .accessibilityRemoveTraits(let s):
            singleAssoc(&out, "accessibilityRemoveTraits") { $0.object { $0.field("_0") { $0.string(s) } } }
        case .searchable(let key, let query, let prompt, let event):
            singleAssoc(&out, "searchable") { o in
                o.object { ob in
                    ob.field("searchKey") { $0.string(key) }
                    ob.field("query") { $0.string(query) }
                    ob.field("prompt") { v in if let prompt { v.string(prompt) } else { v.null() } }
                    ob.field("event") { emitEvent(event, into: &$0) }
                }
            }
        case .focused(let key, let token, let isFocused, let event):
            singleAssoc(&out, "focused") { o in
                o.object { ob in
                    ob.field("focusKey") { $0.string(key) }
                    ob.field("equalsToken") { $0.string(token) }
                    ob.field("isFocused") { $0.bool(isFocused) }
                    ob.field("event") { emitEvent(event, into: &$0) }
                }
            }
        case .onDelete(let e):
            singleAssoc(&out, "onDelete") { $0.object { $0.field("_0") { emitEvent(e, into: &$0) } } }
        case .onMove(let e):
            singleAssoc(&out, "onMove") { $0.object { $0.field("_0") { emitEvent(e, into: &$0) } } }

        // MARK: Scroll & layout (sweep — added at END)
        case .scrollDisabled(let b):
            singleAssoc(&out, "scrollDisabled") { $0.object { $0.field("_0") { $0.bool(b) } } }
        case .scrollIndicators(let vis, let axes):
            singleAssoc(&out, "scrollIndicators") { o in
                o.object { ob in ob.field("_0") { $0.string(vis) }; ob.field("axes") { $0.string(axes) } }
            }
        case .scrollTargetBehavior(let b):
            singleAssoc(&out, "scrollTargetBehavior") { $0.object { $0.field("_0") { $0.string(b) } } }
        case .scrollTargetLayout(let b):
            singleAssoc(&out, "scrollTargetLayout") { $0.object { $0.field("_0") { $0.bool(b) } } }
        case .scrollBounceBehavior(let b, let axes):
            singleAssoc(&out, "scrollBounceBehavior") { o in
                o.object { ob in ob.field("_0") { $0.string(b) }; ob.field("axes") { $0.string(axes) } }
            }
        case .contentMargins(let edges, let length, let placement):
            singleAssoc(&out, "contentMargins") { o in
                o.object { ob in
                    ob.field("edges") { $0.string(edges) }
                    ob.field("length") { $0.number(length) }
                    ob.field("placement") { $0.string(placement) }
                }
            }
        case .safeAreaPadding(let edges, let length, let insets):
            singleAssoc(&out, "safeAreaPadding") { o in
                o.object { ob in
                    ob.field("edges") { $0.string(edges) }
                    ob.field("length") { v in if let length { v.number(length) } else { v.null() } }
                    ob.field("insets") { v in if let insets { emitInsets(insets, into: &v) } else { v.null() } }
                }
            }
        // Additional control styles (styles-views wave) — String payload.
        case .textFieldStyle(let s):
            singleAssoc(&out, "textFieldStyle") { $0.object { $0.field("_0") { $0.string(s) } } }
        case .datePickerStyle(let s):
            singleAssoc(&out, "datePickerStyle") { $0.object { $0.field("_0") { $0.string(s) } } }
        case .groupBoxStyle(let s):
            singleAssoc(&out, "groupBoxStyle") { $0.object { $0.field("_0") { $0.string(s) } } }
        case .controlGroupStyle(let s):
            singleAssoc(&out, "controlGroupStyle") { $0.object { $0.field("_0") { $0.string(s) } } }
        case .disclosureGroupStyle(let s):
            singleAssoc(&out, "disclosureGroupStyle") { $0.object { $0.field("_0") { $0.string(s) } } }
        case .tableStyle(let s):
            singleAssoc(&out, "tableStyle") { $0.object { $0.field("_0") { $0.string(s) } } }

        case .opaque(let s):
            singleAssoc(&out, "opaque") { $0.object { $0.field("_0") { $0.string(s) } } }
        }
    }

    static func emitEvent(_ e: EventID, into out: inout JSONOut) {
        out.object { o in o.field("id") { $0.string(e.id) } }
    }

    /// `IRValue` — Swift's synthesized enum Codable: a single-key object per case
    /// (`.none`→{"none":{}}, `.int(n)`→{"int":{"_0":n}}, `.array([…])`→
    /// {"array":{"_0":[…]}}). Carried in the tree by picker/tabView selection tags.
    static func emitIRValue(_ v: IRValue, into out: inout JSONOut) {
        switch v {
        case .none: stringCase(&out, "none")
        case .bool(let b): singleAssoc(&out, "bool") { $0.object { $0.field("_0") { $0.bool(b) } } }
        case .double(let d): singleAssoc(&out, "double") { $0.object { $0.field("_0") { $0.number(d) } } }
        case .int(let i): singleAssoc(&out, "int") { $0.object { $0.field("_0") { $0.number(i) } } }
        case .string(let s): singleAssoc(&out, "string") { $0.object { $0.field("_0") { $0.string(s) } } }
        case .point(let x, let y):
            singleAssoc(&out, "point") { o in
                o.object { ob in ob.field("_0") { $0.number(x) }; ob.field("_1") { $0.number(y) } }
            }
        case .array(let xs):
            singleAssoc(&out, "array") { o in
                o.object { ob in ob.field("_0") { v2 in v2.array { ar in for x in xs { ar.element { emitIRValue(x, into: &$0) } } } } }
            }
        }
    }

    /// `IRColor` struct → object of its stored-property keys (for colorPicker).
    static func emitIRColorValue(_ c: IRColor, into out: inout JSONOut) {
        out.object { o in
            o.field("r") { $0.number(c.r) }
            o.field("g") { $0.number(c.g) }
            o.field("b") { $0.number(c.b) }
            o.field("a") { $0.number(c.a) }
        }
    }

    /// `IRPickerOption` struct → {tag, label}.
    static func emitPickerOption(_ op: IRPickerOption, into out: inout JSONOut) {
        out.object { o in
            o.field("tag") { emitIRValue(op.tag, into: &$0) }
            o.field("label") { v in v.array { ar in for n in op.label { ar.element { emitNode(n, into: &$0) } } } }
        }
    }

    /// `IRNavDestination` struct → {typeTag, body}.
    static func emitNavDestination(_ d: IRNavDestination, into out: inout JSONOut) {
        out.object { o in
            o.field("typeTag") { $0.string(d.typeTag) }
            o.field("body") { v in v.array { ar in for n in d.body { ar.element { emitNode(n, into: &$0) } } } }
        }
    }

    /// `IRToolbarItem` struct → {placement, content}.
    static func emitToolbarItem(_ it: IRToolbarItem, into out: inout JSONOut) {
        out.object { o in
            o.field("placement") { $0.string(it.placement) }
            o.field("content") { v in v.array { ar in for n in it.content { ar.element { emitNode(n, into: &$0) } } } }
        }
    }

    static func emitColor(_ c: ColorRef, into out: inout JSONOut) {
        switch c {
        case .named(let n):
            singleAssoc(&out, "named") { $0.object { $0.field("_0") { $0.string(n) } } }
        case .rgba(let col):
            singleAssoc(&out, "rgba") { o in
                o.object { ob in
                    ob.field("_0") { v in v.object { c2 in
                        c2.field("r") { $0.number(col.r) }
                        c2.field("g") { $0.number(col.g) }
                        c2.field("b") { $0.number(col.b) }
                        c2.field("a") { $0.number(col.a) }
                    } }
                }
            }
        case .hostToken(let id):
            // Matches the host's synthesized Codable shape `{"hostToken":{"_0":id}}`.
            singleAssoc(&out, "hostToken") { $0.object { $0.field("_0") { $0.string(id) } } }
        }
    }

    static func emitFont(_ f: IRFont, into out: inout JSONOut) {
        out.object { o in
            o.field("style") { v in if let s = f.style { v.string(s.rawValue) } else { v.null() } }
            o.field("size") { v in if let s = f.size { v.number(s) } else { v.null() } }
            o.field("weight") { v in if let w = f.weight { v.string(w.rawValue) } else { v.null() } }
            o.field("design") { v in if let d = f.design { v.string(d.rawValue) } else { v.null() } }
        }
    }

    static func emitInsets(_ i: IREdgeInsets, into out: inout JSONOut) {
        out.object { o in
            o.field("top") { $0.number(i.top) }
            o.field("leading") { $0.number(i.leading) }
            o.field("bottom") { $0.number(i.bottom) }
            o.field("trailing") { $0.number(i.trailing) }
        }
    }

    static func emitShape(_ s: ShapeKind, into out: inout JSONOut) {
        switch s {
        case .rectangle: stringCase(&out, "rectangle")
        case .circle: stringCase(&out, "circle")
        case .ellipse: stringCase(&out, "ellipse")
        case .capsule: stringCase(&out, "capsule")
        case .containerRelative: stringCase(&out, "containerRelative")
        case .roundedRectangle(let r):
            singleAssoc(&out, "roundedRectangle") { $0.object { $0.field("cornerRadius") { $0.number(r) } } }
        case .unevenRoundedRectangle(let tl, let tr, let bl, let br, let style):
            singleAssoc(&out, "unevenRoundedRectangle") { o in
                o.object { ob in
                    ob.field("topLeading") { $0.number(tl) }
                    ob.field("topTrailing") { $0.number(tr) }
                    ob.field("bottomLeading") { $0.number(bl) }
                    ob.field("bottomTrailing") { $0.number(br) }
                    ob.field("style") { $0.string(style.rawValue) }
                }
            }
        }
    }

    // `IRPathCommand` — Swift encodes each case as a single-key object whose key is
    // the case name; a labeled payload becomes an object of those labels, a
    // no-payload case (`closeSubpath`) becomes `{}`.
    static func emitPathCommand(_ c: IRPathCommand, into out: inout JSONOut) {
        switch c {
        case .move(let x, let y):
            singleAssoc(&out, "move") { $0.object { ob in
                ob.field("x") { $0.number(x) }; ob.field("y") { $0.number(y) } } }
        case .line(let x, let y):
            singleAssoc(&out, "line") { $0.object { ob in
                ob.field("x") { $0.number(x) }; ob.field("y") { $0.number(y) } } }
        case .quad(let cpx, let cpy, let x, let y):
            singleAssoc(&out, "quad") { $0.object { ob in
                ob.field("cpx") { $0.number(cpx) }; ob.field("cpy") { $0.number(cpy) }
                ob.field("x") { $0.number(x) }; ob.field("y") { $0.number(y) } } }
        case .curve(let cp1x, let cp1y, let cp2x, let cp2y, let x, let y):
            singleAssoc(&out, "curve") { $0.object { ob in
                ob.field("cp1x") { $0.number(cp1x) }; ob.field("cp1y") { $0.number(cp1y) }
                ob.field("cp2x") { $0.number(cp2x) }; ob.field("cp2y") { $0.number(cp2y) }
                ob.field("x") { $0.number(x) }; ob.field("y") { $0.number(y) } } }
        case .closeSubpath:
            stringCase(&out, "closeSubpath")
        case .addRect(let x, let y, let width, let height):
            singleAssoc(&out, "addRect") { $0.object { ob in
                ob.field("x") { $0.number(x) }; ob.field("y") { $0.number(y) }
                ob.field("width") { $0.number(width) }; ob.field("height") { $0.number(height) } } }
        case .addRoundedRect(let x, let y, let width, let height, let cornerRadius):
            singleAssoc(&out, "addRoundedRect") { $0.object { ob in
                ob.field("x") { $0.number(x) }; ob.field("y") { $0.number(y) }
                ob.field("width") { $0.number(width) }; ob.field("height") { $0.number(height) }
                ob.field("cornerRadius") { $0.number(cornerRadius) } } }
        }
    }

    // `IRGridItem` struct → object of its stored-property keys (size is itself a
    // single-key enum object).
    static func emitGridItem(_ g: IRGridItem, into out: inout JSONOut) {
        out.object { o in
            o.field("size") { emitGridItemSize(g.size, into: &$0) }
            o.field("spacing") { v in if let sp = g.spacing { v.number(sp) } else { v.null() } }
            o.field("alignment") { v in if let a = g.alignment { v.string(a.rawValue) } else { v.null() } }
        }
    }

    static func emitGridItemSize(_ s: IRGridItemSize, into out: inout JSONOut) {
        switch s {
        case .fixed(let x):
            singleAssoc(&out, "fixed") { $0.object { $0.field("_0") { $0.number(x) } } }
        case .flexible(let min, let max):
            singleAssoc(&out, "flexible") { $0.object { ob in
                ob.field("min") { $0.number(min) }
                ob.field("max") { emitLength(max, into: &$0) } } }
        case .adaptive(let min, let max):
            singleAssoc(&out, "adaptive") { $0.object { ob in
                ob.field("min") { $0.number(min) }
                ob.field("max") { emitLength(max, into: &$0) } } }
        }
    }

    static func emitGauge(_ g: IRGaugeData, into out: inout JSONOut) {
        out.object { o in
            o.field("value") { $0.number(g.value) }
            o.field("min") { $0.number(g.min) }
            o.field("max") { $0.number(g.max) }
        }
    }

    static func emitTab(_ t: IRTab, into out: inout JSONOut) {
        out.object { o in
            o.field("tag") { $0.string(t.tag) }
            o.field("tabItem") { v in v.array { ar in for c in t.tabItem { ar.element { emitNode(c, into: &$0) } } } }
            o.field("content") { v in v.array { ar in for c in t.content { ar.element { emitNode(c, into: &$0) } } } }
        }
    }

    // MARK: Unified style vocabulary emitters

    /// `IRUnitPoint`: a named-case fast-path is a payload-free case → {"center":{}};
    /// `.xy(x:,y:)` → {"xy":{"x":…,"y":…}} (Swift's synthesized labeled-payload shape).
    static func emitUnitPoint(_ p: IRUnitPoint, into out: inout JSONOut) {
        switch p {
        case .center: stringCase(&out, "center")
        case .top: stringCase(&out, "top")
        case .bottom: stringCase(&out, "bottom")
        case .leading: stringCase(&out, "leading")
        case .trailing: stringCase(&out, "trailing")
        case .topLeading: stringCase(&out, "topLeading")
        case .topTrailing: stringCase(&out, "topTrailing")
        case .bottomLeading: stringCase(&out, "bottomLeading")
        case .bottomTrailing: stringCase(&out, "bottomTrailing")
        case .xy(let x, let y):
            singleAssoc(&out, "xy") { o in
                o.object { ob in ob.field("x") { $0.number(x) }; ob.field("y") { $0.number(y) } }
            }
        }
    }

    static func emitGradientStop(_ s: IRGradientStop, into out: inout JSONOut) {
        out.object { o in
            o.field("color") { emitColor(s.color, into: &$0) }
            o.field("location") { $0.number(s.location) }
        }
    }

    static func emitGradient(_ g: IRGradient, into out: inout JSONOut) {
        out.object { o in
            o.field("stops") { v in v.array { ar in for s in g.stops { ar.element { emitGradientStop(s, into: &$0) } } } }
        }
    }

    static func emitStrokeStyle(_ s: IRStrokeStyle, into out: inout JSONOut) {
        out.object { o in
            o.field("lineWidth") { $0.number(s.lineWidth) }
            o.field("cap") { $0.string(s.cap) }
            o.field("join") { $0.string(s.join) }
            o.field("miterLimit") { $0.number(s.miterLimit) }
            o.field("dash") { v in v.array { ar in for d in s.dash { ar.element { $0.number(d) } } } }
            o.field("dashPhase") { $0.number(s.dashPhase) }
        }
    }

    static func emitShadowStyle(_ s: IRShadowStyle, into out: inout JSONOut) {
        out.object { o in
            o.field("color") { v in if let c = s.color { emitColor(c, into: &v) } else { v.null() } }
            o.field("radius") { $0.number(s.radius) }
            o.field("x") { $0.number(s.x) }
            o.field("y") { $0.number(s.y) }
        }
    }

    /// `IRShapeStyle`: a single-key object per case (Swift's synthesized enum
    /// Codable). `.material` carries a raw-String enum (emitted as a bare string,
    /// NOT a single-key object — matching how `IRFont.Weight` emits).
    static func emitShapeStyle(_ s: IRShapeStyle, into out: inout JSONOut) {
        switch s {
        case .color(let c):
            singleAssoc(&out, "color") { $0.object { $0.field("_0") { emitColor(c, into: &$0) } } }
        case .linearGradient(let g, let sp, let ep):
            singleAssoc(&out, "linearGradient") { o in
                o.object { ob in
                    ob.field("_0") { emitGradient(g, into: &$0) }
                    ob.field("startPoint") { emitUnitPoint(sp, into: &$0) }
                    ob.field("endPoint") { emitUnitPoint(ep, into: &$0) }
                }
            }
        case .radialGradient(let g, let c, let sr, let er):
            singleAssoc(&out, "radialGradient") { o in
                o.object { ob in
                    ob.field("_0") { emitGradient(g, into: &$0) }
                    ob.field("center") { emitUnitPoint(c, into: &$0) }
                    ob.field("startRadius") { $0.number(sr) }
                    ob.field("endRadius") { $0.number(er) }
                }
            }
        case .angularGradient(let g, let c, let sa, let ea):
            singleAssoc(&out, "angularGradient") { o in
                o.object { ob in
                    ob.field("_0") { emitGradient(g, into: &$0) }
                    ob.field("center") { emitUnitPoint(c, into: &$0) }
                    ob.field("startAngle") { $0.number(sa) }
                    ob.field("endAngle") { $0.number(ea) }
                }
            }
        case .material(let m):
            singleAssoc(&out, "material") { $0.object { $0.field("_0") { $0.string(m.rawValue) } } }
        case .hierarchical(let l):
            singleAssoc(&out, "hierarchical") { $0.object { $0.field("_0") { $0.number(l) } } }
        case .semantic(let name):
            singleAssoc(&out, "semantic") { $0.object { $0.field("_0") { $0.string(name) } } }
        case .shadow(let style):
            singleAssoc(&out, "shadow") { $0.object { $0.field("_0") { emitShadowStyle(style, into: &$0) } } }
        }
    }

    static func emitAnimation(_ a: IRAnimation, into out: inout JSONOut) {
        out.object { o in
            o.field("curve") { $0.string(a.curve) }
            o.field("duration") { v in if let d = a.duration { v.number(d) } else { v.null() } }
            o.field("response") { v in if let r = a.response { v.number(r) } else { v.null() } }
            o.field("dampingFraction") { v in if let f = a.dampingFraction { v.number(f) } else { v.null() } }
            o.field("delay") { v in if let d = a.delay { v.number(d) } else { v.null() } }
            o.field("speed") { v in if let s = a.speed { v.number(s) } else { v.null() } }
            o.field("repeatCount") { v in if let r = a.repeatCount { v.number(r) } else { v.null() } }
            o.field("autoreverses") { v in if let ar = a.autoreverses { v.bool(ar) } else { v.null() } }
        }
    }

    static func emitTransition(_ t: IRTransition, into out: inout JSONOut) {
        switch t {
        case .identity: stringCase(&out, "identity")
        case .opacity: stringCase(&out, "opacity")
        case .scale(let s, let a):
            singleAssoc(&out, "scale") { o in
                o.object { ob in ob.field("scale") { $0.number(s) }; ob.field("anchor") { emitUnitPoint(a, into: &$0) } }
            }
        case .slide: stringCase(&out, "slide")
        case .move(let e):
            singleAssoc(&out, "move") { $0.object { $0.field("edge") { $0.string(e) } } }
        case .push(let e):
            singleAssoc(&out, "push") { $0.object { $0.field("edge") { $0.string(e) } } }
        case .offset(let x, let y):
            singleAssoc(&out, "offset") { o in
                o.object { ob in ob.field("x") { $0.number(x) }; ob.field("y") { $0.number(y) } }
            }
        case .blurReplace: stringCase(&out, "blurReplace")
        case .combined(let ts):
            singleAssoc(&out, "combined") { o in
                o.object { ob in ob.field("_0") { v in v.array { ar in
                    for t in ts { ar.element { emitTransition(t, into: &$0) } } } } }
            }
        case .asymmetric(let i, let r):
            singleAssoc(&out, "asymmetric") { o in
                o.object { ob in
                    ob.field("insertion") { emitTransition(i, into: &$0) }
                    ob.field("removal") { emitTransition(r, into: &$0) }
                }
            }
        }
    }

    // `IRLength`: a finite `.points(x)` → {"points":{"_0":x}} (unlabeled payload),
    // and the payload-FREE `.infinity` → {"infinity":{}} — EXACTLY Swift's
    // synthesized Codable for a mixed enum (verified: a bare "infinity" string
    // does NOT decode; JSONDecoder expects the single-key object form).
    static func emitLength(_ l: IRLength, into out: inout JSONOut) {
        switch l {
        case .points(let x):
            singleAssoc(&out, "points") { $0.object { $0.field("_0") { $0.number(x) } } }
        case .infinity:
            stringCase(&out, "infinity")
        }
    }

    // Swift's synthesized enum Codable encodes EVERY case as a single-key
    // object whose key is the case name. A payload case carries an object of
    // its labeled values; a payload-FREE case carries an empty object `{}`.
    static func singleAssoc(_ out: inout JSONOut, _ caseName: StaticString,
                            _ payload: (inout JSONOut) -> Void) {
        out.object { o in o.field(caseName) { payload(&$0) } }
    }
    static func stringCase(_ out: inout JSONOut, _ caseName: StaticString) {
        out.object { o in o.field(caseName) { $0.object { _ in } } }
    }
}
