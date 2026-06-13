// PatchValueEncoder.swift — recursive value → JSON marshalling for the lowered
// guest body's inputs.
// ======================================================================
// `PatchInstanceInputs` (ViewPatching.swift) marshals a live view instance's
// stored properties + property-wrapper values into the flat inputs JSON the
// lowered WASM body scans. SCALARS marshal directly (String/Bool/Int/Double…);
// this file widens that to the COMMON NON-SCALAR value types a body reads from
// `@State`/`@Binding`/`let`, so the guest renders the REAL current value rather
// than a guest-side literal default:
//
//   * struct / class            → a nested JSON object of its stored properties
//   * enum                      → {"case":"<label>"[,"_0":…,"_1":…]} (or a bare
//                                 string for a no-payload case, see below)
//   * Array / Set               → a JSON array of encoded elements
//   * Dictionary                → a JSON object (String keys) else [[k,v],…]
//   * Optional                  → the encoded wrapped value, or `null`
//   * Date                      → epoch seconds as a JSON number
//   * UUID / URL                → its string form
//
// This is the SDK READ side: it carries a faithful snapshot of the value INTO
// the guest. The guest BIND side (the engine's `SwiftUIGuestEmitter`) can only
// reconstruct a subset of these without Foundation/Codable (scalars + arrays of
// scalars); for richer shapes the engine demotes the view to native rather than
// bind a wrong default. Encoding here is still worthwhile: it is the single
// source of the value's wire form, the dispatch write-back path round-trips it,
// and future guest decoders can widen against the SAME format.
//
// Everything is Mirror-driven (no per-type conformance needed) with a bounded
// recursion depth so a cyclic reference graph can't spin. A value the encoder
// genuinely cannot represent yields `nil` — the caller then omits the key, and
// the input falls back to its guest-side default (and, when the body reads it,
// the engine has already kept the view native).

#if canImport(SwiftUI)
import Foundation

/// Recursively encodes an arbitrary value into a JSON fragment string, or nil if
/// it isn't representable. Pure value semantics: it only READS via Mirror.
enum PatchValueEncoder {

    /// Max nesting depth. Deep enough for realistic view models; bounded so a
    /// reference cycle (class → … → same class) can't recurse forever.
    static let maxDepth = 12

    /// A JSON fragment for `value`, or nil if it can't be represented. `depth`
    /// guards recursion; callers start at 0.
    static func encode(_ value: Any, depth: Int = 0) -> String? {
        if depth > maxDepth { return nil }

        // 1) Scalars (+ String) — the existing fast path. Keep this FIRST so an
        //    Int/Bool/Double never falls into the Mirror branches below.
        if let scalar = PatchInstanceInputs.scalarJSONFragment(value) {
            return scalar
        }

        // 2) Foundation leaf types that have a canonical scalar wire form.
        if let date = value as? Date {
            return PatchInstanceInputs.scalarJSONFragment(date.timeIntervalSince1970)
        }
        if let uuid = value as? UUID {
            return PatchInstanceInputs.quotedJSONString(uuid.uuidString)
        }
        if let url = value as? URL {
            return PatchInstanceInputs.quotedJSONString(url.absoluteString)
        }
        if let data = value as? Data {
            // Bytes as a JSON array of integers — faithful + guest-parseable.
            return "[" + data.map(String.init).joined(separator: ",") + "]"
        }

        // 3) Structured values via Mirror.
        let mirror = Mirror(reflecting: value)
        switch mirror.displayStyle {
        case .optional:
            // `.some(x)` has exactly one child labelled "some"; `.none` has none.
            if let child = mirror.children.first {
                return encode(child.value, depth: depth + 1)
            }
            return "null"

        case .collection, .set:
            return encodeArray(mirror, depth: depth)

        case .dictionary:
            return encodeDictionary(mirror, depth: depth)

        case .enum:
            return encodeEnum(value, mirror: mirror, depth: depth)

        case .struct, .class:
            return encodeObject(mirror, depth: depth)

        default:
            // .tuple / unknown / no displayStyle. A tuple has indexed/`.N` labels;
            // encode it as an object best-effort (rare in view state). If it has no
            // children and isn't a recognized scalar, it's not representable.
            if mirror.children.isEmpty { return nil }
            return encodeObject(mirror, depth: depth)
        }
    }

    // MARK: - Aggregates

    private static func encodeArray(_ mirror: Mirror, depth: Int) -> String? {
        var parts: [String] = []
        for child in mirror.children {
            guard let frag = encode(child.value, depth: depth + 1) else { return nil }
            parts.append(frag)
        }
        return "[" + parts.joined(separator: ",") + "]"
    }

    private static func encodeDictionary(_ mirror: Mirror, depth: Int) -> String? {
        // Swift's Mirror of a Dictionary yields children whose value is a (key,
        // value) tuple. Try to emit a JSON object when keys are strings (or
        // string-convertible scalars); otherwise emit an array of [k, v] pairs so
        // non-string keys don't silently collapse.
        var objectEntries: [(String, String)] = []
        var pairEntries: [String] = []
        var keysAreStringy = true
        for child in mirror.children {
            let pair = Mirror(reflecting: child.value)
            let elems = Array(pair.children)
            guard elems.count == 2 else { return nil }
            let keyVal = elems[0].value
            let valVal = elems[1].value
            guard let valFrag = encode(valVal, depth: depth + 1) else { return nil }
            if let keyStr = stringKey(keyVal) {
                objectEntries.append((keyStr, valFrag))
            } else {
                keysAreStringy = false
            }
            guard let keyFrag = encode(keyVal, depth: depth + 1) else { return nil }
            pairEntries.append("[" + keyFrag + "," + valFrag + "]")
        }
        if keysAreStringy {
            // Deterministic key order for stable, cacheable output.
            objectEntries.sort { $0.0 < $1.0 }
            return "{" + objectEntries.map {
                "\(PatchInstanceInputs.quotedJSONString($0.0)):\($0.1)"
            }.joined(separator: ",") + "}"
        }
        return "[" + pairEntries.joined(separator: ",") + "]"
    }

    /// A JSON object key string for a dictionary key, when it's a String or a
    /// scalar with an unambiguous textual form. Non-stringy keys return nil.
    private static func stringKey(_ value: Any) -> String? {
        switch value {
        case let s as String: return s
        case let i as Int: return String(i)
        case let i as Int32: return String(i)
        case let i as Int64: return String(i)
        case let u as UInt: return String(u)
        default: return nil
        }
    }

    // MARK: - Enum

    private static func encodeEnum(_ value: Any, mirror: Mirror, depth: Int) -> String? {
        // A no-associated-value case mirrors with zero children; its label is the
        // case name (`String(describing:)` of a bare case is exactly that name).
        // A case WITH payload mirrors with one child whose label is the case name
        // and whose value is the payload (a single value, or a tuple of values).
        if let child = mirror.children.first {
            let caseName = child.label ?? String(describing: value)
            // The payload: a tuple (multiple associated values) decomposes to
            // _0/_1/…; a single value becomes _0.
            let payloadMirror = Mirror(reflecting: child.value)
            var fields: [(String, String)] = [("case", PatchInstanceInputs.quotedJSONString(caseName))]
            if payloadMirror.displayStyle == .tuple {
                var i = 0
                for elem in payloadMirror.children {
                    guard let frag = encode(elem.value, depth: depth + 1) else { return nil }
                    // Prefer the tuple's own label (a labelled associated value),
                    // else positional `_0`,`_1`,…
                    let key = elem.label.flatMap { $0.hasPrefix(".") ? nil : $0 } ?? "_\(i)"
                    fields.append((key, frag))
                    i += 1
                }
            } else {
                guard let frag = encode(child.value, depth: depth + 1) else { return nil }
                fields.append(("_0", frag))
            }
            return "{" + fields.map { "\(PatchInstanceInputs.quotedJSONString($0.0)):\($0.1)" }
                .joined(separator: ",") + "}"
        }
        // No payload: emit {"case":"label"} for a uniform object shape the guest /
        // write-back can read by the "case" key.
        let caseName = String(describing: value)
        return "{\"case\":\(PatchInstanceInputs.quotedJSONString(caseName))}"
    }

    // MARK: - Struct / class

    private static func encodeObject(_ mirror: Mirror, depth: Int) -> String? {
        var entries: [(String, String)] = []
        // Walk the type's own children plus any superclass mirror (class
        // hierarchies expose inherited stored props via `superclassMirror`).
        var current: Mirror? = mirror
        var seen = Set<String>()
        while let m = current {
            for child in m.children {
                guard let label = child.label, !label.isEmpty, !seen.contains(label) else { continue }
                // A property-wrapper field inside a value type surfaces as `_name`;
                // present it under the user-facing key (`name`). We encode its stored
                // value as Mirror reflects it (a nested live `@State` box isn't
                // faithfully readable off its SwiftUI storage, so we don't special-case
                // it — plain value-type fields are the norm here).
                let key = label.hasPrefix("_") ? String(label.dropFirst()) : label
                guard !key.isEmpty else { continue }
                guard let frag = encode(child.value, depth: depth + 1) else { return nil }
                seen.insert(label)
                entries.append((key, frag))
            }
            current = m.superclassMirror
        }
        // Stable key order.
        entries.sort { $0.0 < $1.0 }
        return "{" + entries.map { "\(PatchInstanceInputs.quotedJSONString($0.0)):\($0.1)" }
            .joined(separator: ",") + "}"
    }
}
#endif
