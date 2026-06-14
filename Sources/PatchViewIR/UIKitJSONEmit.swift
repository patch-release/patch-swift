// UIKitJSONEmit.swift — a Foundation-FREE JSON serializer for the UIKitNode tree.
// ==============================================================================
// The UIKit analogue of `JSONEmit.swift` (the SwiftUI IR emitter). `JSONEncoder`
// needs Foundation, which the T0 *Embedded* Swift wasm tier does NOT have, so the
// IR must serialize itself with no Foundation. This hand-rolled emitter produces
// JSON byte-for-byte compatible with the host's `JSONDecoder` reading
// `UIKitEmission` — so the SAME host renderer decodes both the T2 (Foundation)
// and T0 (embedded) guests.
//
// It REUSES the `JSONOut`/`ObjectWriter`/`ArrayWriter` plumbing AND the shared
// value-type emitters (`emitColor`/`emitFont`/`emitEvent`/`singleAssoc`/
// `stringCase`) defined in `JSONEmit.swift` — they live in the same module, so
// there is exactly one JSON-string builder.
//
// It emits the EXACT shape Swift's synthesized `Codable` produces:
//   * structs as objects with their stored-property keys,
//   * enums-with-associated-values as a single-key object whose key is the case
//     name and whose value is an object of the case's labeled payload
//     (single unlabeled arg → `_0`),
//   * enums-without-payload as a single-key object with an empty `{}` payload
//     (NOT a bare string — matches `EmbeddedJSON.stringCase`).
//
// This file is `Foundation`-free and compiles under Embedded Swift.

public enum UIKitEmbeddedJSON {
    /// Encode a `UIKitEmission` to JSON bytes WITHOUT Foundation.
    public static func encode(_ emission: UIKitEmission) -> [UInt8] {
        var out = JSONOut()
        emitEmission(emission, into: &out)
        return out.bytes
    }

    static func emitEmission(_ e: UIKitEmission, into out: inout JSONOut) {
        out.object { o in
            o.field("root") { emitNode(e.root, into: &$0) }
            if let cov = e.coverage {
                o.field("coverage") { co in
                    co.object { c in
                        c.field("totalNodes") { $0.number(cov.totalNodes) }
                        c.field("slotNodes") { $0.number(cov.slotNodes) }
                        c.field("totalConstraints") { $0.number(cov.totalConstraints) }
                    }
                }
            }
        }
    }

    static func emitNode(_ node: UIKitNode, into out: inout JSONOut) {
        out.object { o in
            o.field("kind") { emitKind(node.kind, into: &$0) }
            o.field("props") { emitProps(node.props, into: &$0) }
            o.field("constraints") { v in
                v.array { ar in for c in node.constraints { ar.element { emitConstraint(c, into: &$0) } } }
            }
        }
    }

    // MARK: - Node kind

    static func emitKind(_ kind: UIKitNodeKind, into out: inout JSONOut) {
        switch kind {
        case .label(let text, let font, let textColor, let numberOfLines, let alignment):
            EmbeddedJSON.singleAssoc(&out, "label") { o in
                o.object { ob in
                    ob.field("text") { $0.string(text) }
                    ob.field("font") { v in if let font { EmbeddedJSON.emitFont(font, into: &v) } else { v.null() } }
                    ob.field("textColor") { v in if let textColor { EmbeddedJSON.emitColor(textColor, into: &v) } else { v.null() } }
                    ob.field("numberOfLines") { v in if let numberOfLines { v.number(numberOfLines) } else { v.null() } }
                    ob.field("alignment") { v in if let alignment { v.string(alignment.rawValue) } else { v.null() } }
                }
            }
        case .button(let title, let titleColor, let font, let action):
            EmbeddedJSON.singleAssoc(&out, "button") { o in
                o.object { ob in
                    ob.field("title") { $0.string(title) }
                    ob.field("titleColor") { v in if let titleColor { EmbeddedJSON.emitColor(titleColor, into: &v) } else { v.null() } }
                    ob.field("font") { v in if let font { EmbeddedJSON.emitFont(font, into: &v) } else { v.null() } }
                    ob.field("action") { EmbeddedJSON.emitEvent(action, into: &$0) }
                }
            }
        case .imageView(let image, let tintColor, let contentMode):
            EmbeddedJSON.singleAssoc(&out, "imageView") { o in
                o.object { ob in
                    ob.field("image") { emitImageRef(image, into: &$0) }
                    ob.field("tintColor") { v in if let tintColor { EmbeddedJSON.emitColor(tintColor, into: &v) } else { v.null() } }
                    ob.field("contentMode") { v in if let contentMode { v.string(contentMode.rawValue) } else { v.null() } }
                }
            }
        case .stackView(let axis, let spacing, let alignment, let distribution, let arranged):
            EmbeddedJSON.singleAssoc(&out, "stackView") { o in
                o.object { ob in
                    ob.field("axis") { $0.string(axis.rawValue) }
                    ob.field("spacing") { v in if let spacing { v.number(spacing) } else { v.null() } }
                    ob.field("alignment") { v in if let alignment { v.string(alignment.rawValue) } else { v.null() } }
                    ob.field("distribution") { v in if let distribution { v.string(distribution.rawValue) } else { v.null() } }
                    ob.field("arranged") { v in v.array { ar in for c in arranged { ar.element { emitNode(c, into: &$0) } } } }
                }
            }
        case .containerView(let children):
            EmbeddedJSON.singleAssoc(&out, "containerView") { o in
                o.object { ob in
                    ob.field("children") { v in v.array { ar in for c in children { ar.element { emitNode(c, into: &$0) } } } }
                }
            }
        case .switchControl(let isOn, let event):
            EmbeddedJSON.singleAssoc(&out, "switchControl") { o in
                o.object { ob in
                    ob.field("isOn") { $0.bool(isOn) }
                    ob.field("event") { EmbeddedJSON.emitEvent(event, into: &$0) }
                }
            }
        case .uiSlider(let value, let mn, let mx, let event):
            EmbeddedJSON.singleAssoc(&out, "uiSlider") { o in
                o.object { ob in
                    ob.field("value") { $0.number(value) }
                    ob.field("min") { $0.number(mn) }
                    ob.field("max") { $0.number(mx) }
                    ob.field("event") { EmbeddedJSON.emitEvent(event, into: &$0) }
                }
            }
        case .uiTextField(let text, let placeholder, let event):
            EmbeddedJSON.singleAssoc(&out, "uiTextField") { o in
                o.object { ob in
                    ob.field("text") { $0.string(text) }
                    ob.field("placeholder") { $0.string(placeholder) }
                    ob.field("event") { EmbeddedJSON.emitEvent(event, into: &$0) }
                }
            }
        case .customSlot(let id, let label):
            EmbeddedJSON.singleAssoc(&out, "customSlot") { o in
                o.object { ob in
                    ob.field("id") { $0.string(id) }
                    ob.field("label") { $0.string(label) }
                }
            }
        }
    }

    // MARK: - View props

    static func emitProps(_ p: UIKitViewProps, into out: inout JSONOut) {
        out.object { o in
            o.field("id") { $0.string(p.id) }
            o.field("backgroundColor") { v in if let c = p.backgroundColor { EmbeddedJSON.emitColor(c, into: &v) } else { v.null() } }
            o.field("cornerRadius") { v in if let r = p.cornerRadius { v.number(r) } else { v.null() } }
            o.field("clipsToBounds") { v in if let b = p.clipsToBounds { v.bool(b) } else { v.null() } }
            o.field("alpha") { v in if let a = p.alpha { v.number(a) } else { v.null() } }
            o.field("isHidden") { v in if let h = p.isHidden { v.bool(h) } else { v.null() } }
            o.field("tintColor") { v in if let c = p.tintColor { EmbeddedJSON.emitColor(c, into: &v) } else { v.null() } }
            o.field("accessibilityIdentifier") { v in if let s = p.accessibilityIdentifier { v.string(s) } else { v.null() } }
        }
    }

    // MARK: - Auto Layout

    /// `IRConstraint` struct → object of its stored-property keys (`second` is an
    /// optional `IRAnchorRef`; `priority` is an optional Double).
    static func emitConstraint(_ c: IRConstraint, into out: inout JSONOut) {
        out.object { o in
            o.field("first") { $0.string(c.first.rawValue) }
            o.field("relation") { $0.string(c.relation.rawValue) }
            o.field("second") { v in if let s = c.second { emitAnchorRef(s, into: &v) } else { v.null() } }
            o.field("multiplier") { $0.number(c.multiplier) }
            o.field("constant") { $0.number(c.constant) }
            o.field("priority") { v in if let p = c.priority { v.number(p) } else { v.null() } }
        }
    }

    /// `IRAnchorRef` struct → {target, anchor}.
    static func emitAnchorRef(_ r: IRAnchorRef, into out: inout JSONOut) {
        out.object { o in
            o.field("target") { emitAnchorTarget(r.target, into: &$0) }
            o.field("anchor") { $0.string(r.anchor.rawValue) }
        }
    }

    /// `IRAnchorTarget` — Swift's synthesized enum Codable: payload-free cases
    /// (`.superview`/`.safeArea`/`.selfView`) → `{"superview":{}}`; the
    /// single-unlabeled-payload `.sibling(id:)` → `{"sibling":{"id":…}}` (a
    /// LABELED associated value uses its label, not `_0`).
    static func emitAnchorTarget(_ t: IRAnchorTarget, into out: inout JSONOut) {
        switch t {
        case .superview: EmbeddedJSON.stringCase(&out, "superview")
        case .safeArea: EmbeddedJSON.stringCase(&out, "safeArea")
        case .selfView: EmbeddedJSON.stringCase(&out, "selfView")
        case .sibling(let id):
            EmbeddedJSON.singleAssoc(&out, "sibling") { $0.object { $0.field("id") { $0.string(id) } } }
        }
    }

    // MARK: - Image ref

    /// `IRImageRef` — single-key enum: `.systemName(s)` → {"systemName":{"_0":s}},
    /// `.assetName(s)` → {"assetName":{"_0":s}} (unlabeled payload → `_0`).
    static func emitImageRef(_ r: IRImageRef, into out: inout JSONOut) {
        switch r {
        case .systemName(let s):
            EmbeddedJSON.singleAssoc(&out, "systemName") { $0.object { $0.field("_0") { $0.string(s) } } }
        case .assetName(let s):
            EmbeddedJSON.singleAssoc(&out, "assetName") { $0.object { $0.field("_0") { $0.string(s) } } }
        }
    }
}
