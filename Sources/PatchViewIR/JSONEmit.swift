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
        case .image(let name):
            singleAssoc(&out, "image") { $0.object { $0.field("systemName") { $0.string(name) } } }
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
        case .button(let id, let label):
            singleAssoc(&out, "button") { o in
                o.object { ob in
                    ob.field("actionID") { $0.string(id) }
                    ob.field("label") { v in v.array { ar in for c in label { ar.element { emitNode(c, into: &$0) } } } }
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
        case .opaque(let id, let label):
            singleAssoc(&out, "opaque") { o in
                o.object { ob in
                    ob.field("id") { $0.string(id) }
                    ob.field("label") { $0.string(label) }
                }
            }
        }
    }

    static func emitModifier(_ m: Modifier, into out: inout JSONOut) {
        switch m {
        case .font(let f):
            singleAssoc(&out, "font") { $0.object { $0.field("_0") { emitFont(f, into: &$0) } } }
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
        case .opaque(let s):
            singleAssoc(&out, "opaque") { $0.object { $0.field("_0") { $0.string(s) } } }
        }
    }

    static func emitEvent(_ e: EventID, into out: inout JSONOut) {
        out.object { o in o.field("id") { $0.string(e.id) } }
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
        case .roundedRectangle(let r):
            singleAssoc(&out, "roundedRectangle") { $0.object { $0.field("cornerRadius") { $0.number(r) } } }
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
