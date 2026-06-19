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

    /// The TRUE enum case name, bypassing any custom `description`. `String(describing:)`
    /// of an enum that also conforms to `CustomStringConvertible` returns its custom
    /// description (bug #46: `Status.archived` instead of `archived`) — so the guest, which
    /// compares against the case LABEL, mismatched and rendered the FIRST case. The Swift
    /// runtime's `swift_EnumCaseName` returns the real label regardless of conformance; it
    /// returns nil for a non-enum, so callers fall back safely.
    @_silgen_name("swift_EnumCaseName")
    private static func _swiftEnumCaseName<T>(_ value: T) -> UnsafePointer<CChar>?

    static func enumCaseName(_ value: Any) -> String? {
        func project<T>(_ x: T) -> String? {
            guard let p = _swiftEnumCaseName(x) else { return nil }
            return String(validatingCString: p)
        }
        return _openExistential(value, do: project)
    }

    private static func encodeEnum(_ value: Any, mirror: Mirror, depth: Int) -> String? {
        // A no-associated-value case mirrors with zero children; its label is the
        // case name. A case WITH payload mirrors with one child whose label is the
        // case name and whose value is the payload (a single value, or a tuple).
        if let child = mirror.children.first {
            // Prefer the runtime case name (bypasses a custom `description`), then the
            // payload child's label, then a last-resort `String(describing:)`.
            let caseName = enumCaseName(value) ?? child.label ?? String(describing: value)
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
        // write-back can read by the "case" key. Use the runtime case name so a
        // `CustomStringConvertible` enum doesn't leak its custom description (bug #46).
        let caseName = enumCaseName(value) ?? String(describing: value)
        return "{\"case\":\(PatchInstanceInputs.quotedJSONString(caseName))}"
    }

    // MARK: - Property-wrapper unwrap

    /// True iff `value` is a Combine `Published<Value>` wrapper (by type name — no
    /// `import Combine` needed). Used to SKIP a `@Published` whose storage isn't a
    /// settled `.value` (bug #9) rather than encode its opaque internals.
    static func isPublished(_ value: Any) -> Bool {
        String(describing: type(of: value)).hasPrefix("Published<")
    }

    /// Unwrap a Combine `Published<Value>` to its current `Value`, or nil if `value`
    /// isn't a `Published`. `Published` mirrors to a single `storage` child — an enum
    /// `.value(Value)` (the normal settled state) OR `.publisher(Publisher)` (after a
    /// Combine subscriber attached, e.g. `service.itemsPublisher.assign(to: &$items)`).
    /// We reach the current `Value` via Mirror in BOTH states (no `import Combine` /
    /// no generic-parameter knowledge needed), so a classic `@Published var items: [Row]`
    /// marshals as a clean array regardless of whether it's settled or publisher-driven.
    ///
    /// BUG #3: the dominant MVVM pattern is `@Published var items` with a Combine
    /// subscriber (`.assign(to:&$items)` / `$items.sink`), which permanently moves the
    /// storage into `.publisher`. The `.publisher` case wraps a `PublishedSubject` whose
    /// `currentValue` IS the live value — so we reach it (rather than skipping the field,
    /// which marshalled an EMPTY object → a populated `ForEach(vm.items)` rendered ZERO
    /// rows). Only when neither shape yields a value does the caller skip the field.
    static func unwrapPublished(_ value: Any) -> Any? {
        guard isPublished(value) else { return nil }
        let m = Mirror(reflecting: value)
        guard let storage = m.children.first(where: { $0.label == "storage" })?.value else { return nil }
        let sm = Mirror(reflecting: storage)
        guard sm.displayStyle == .enum, let c = sm.children.first else { return nil }
        if c.label == "value" {
            // `.value(Value)` has a single associated value: `c.value` IS the wrapped value.
            return c.value
        }
        if c.label == "publisher" {
            // `.publisher(Published.Publisher)` → `.subject` (a `PublishedSubject`, a
            // CurrentValueSubject) → `.currentValue` holds the live `Value`. Walk it by
            // label only (Mirror-driven, Combine-internal-name-stable since iOS 13).
            let pm = Mirror(reflecting: c.value)
            guard let subject = pm.children.first(where: { $0.label == "subject" })?.value else { return nil }
            let subjMirror = Mirror(reflecting: subject)
            if let current = subjMirror.children.first(where: { $0.label == "currentValue" })?.value {
                return current
            }
            return nil
        }
        return nil
    }

    // MARK: - Struct / class

    /// Whether `typeName` is a SwiftUI/Combine property-wrapper backing type — its
    /// Mirror child surfaces under `_name` but the developer + the CLI guest read the
    /// STRIPPED `name`. Used to decide the bug #47/#70 raw-name emit.
    private static func isPropertyWrapperTypeName(_ typeName: String) -> Bool {
        for prefix in ["Published<", "State<", "Binding<", "AppStorage<", "SceneStorage<",
                       "StateObject<", "ObservedObject<", "EnvironmentObject<",
                       "Environment<", "FocusState<", "Bindable<", "ObservationStateRegistrar"] {
            if typeName.hasPrefix(prefix) { return true }
        }
        return false
    }

    private static func encodeObject(_ mirror: Mirror, depth: Int) -> String? {
        var entries: [(String, String)] = []
        // Walk the type's own children plus any superclass mirror (class
        // hierarchies expose inherited stored props via `superclassMirror`).
        // Detect macro backing: `@Observable`/`@Model` inject a `_$observationRegistrar`
        // (and `@Model` a `_$backingData`). When present, the `_name` children are MACRO
        // BACKING (read by the developer + guest as the STRIPPED `name`), so we must NOT
        // also emit the raw `_name` (bug #47/#70's raw-emit applies ONLY to a PLAIN field
        // literally named `_name`, which has no such macro plumbing).
        var hasMacroPlumbing = false
        do {
            var probe: Mirror? = mirror
            while let pm = probe {
                if pm.children.contains(where: { ($0.label ?? "").hasPrefix("_$") }) {
                    hasMacroPlumbing = true; break
                }
                probe = pm.superclassMirror
            }
        }
        var current: Mirror? = mirror
        var seen = Set<String>()
        while let m = current {
            for child in m.children {
                guard let label = child.label, !label.isEmpty, !seen.contains(label) else { continue }
                // Skip macro-generated plumbing. The `@Observable` / `@Model` macros inject
                // `_$observationRegistrar` (and `@Model` a `_$backingData`); these aren't view
                // data and don't encode (the registrar mirrors to non-representable internals),
                // and WITHOUT this skip a single such child would fail the WHOLE object (the
                // `encode(...)` below) — so an `@Observable` view-model would never marshal.
                // Skipping `_$…` lets its real stored fields (`_items`, surfaced under `items`)
                // encode. A normal field never starts with `_$`.
                if label.hasPrefix("_$") { seen.insert(label); continue }
                // A property-wrapper field inside a value type surfaces as `_name`;
                // present it under the user-facing key (`name`). We encode its stored
                // value as Mirror reflects it (a nested live `@State` box isn't
                // faithfully readable off its SwiftUI storage, so we don't special-case
                // it — plain value-type fields are the norm here).
                //
                // BUG #47/#70: a SOURCE field literally named `_count`/`_id` would be
                // dropped if we ONLY emitted the stripped key — the CLI guest scans the
                // RAW source name (`binding.pattern.trimmedDescription`, including the
                // leading underscore), so `m._count` read its guest default.
                let strippedKey = label.hasPrefix("_") ? String(label.dropFirst()) : label
                guard !strippedKey.isEmpty else { continue }
                // A classic `@Published var x` inside an ObservableObject surfaces as
                // `_x: Published<X>`, which Mirror exposes as `{storage: .value(X)}` — so
                // without unwrapping, `x` would marshal as `{"storage":{"case":"value",...}}`
                // (useless to the guest). Unwrap to the real value so a `@Published`
                // collection marshals as a clean array (classic MVVM, alongside @Observable).
                seen.insert(label)
                let childValue: Any
                // BUG #47/#70 key choice. A `_name` label is EITHER (a) a property-wrapper /
                // macro BACKING field, whose developer + CLI-guest name is the STRIPPED
                // `name`, OR (b) a PLAIN field literally named `_name`, whose source/guest
                // name IS `_name`. Decide which, so we emit the ONE key the guest scans:
                //   * a known wrapper TYPE (`Published<…>` etc.)                → STRIPPED
                //   * any `_name` field on an `@Observable`/`@Model` (macro plumbing) → STRIPPED
                //   * else (a plain struct/class field literally named `_name`)  → RAW
                let valueTypeName = String(describing: type(of: child.value))
                let isWrapperBacking = label.hasPrefix("_")
                    && (PatchValueEncoder.isPropertyWrapperTypeName(valueTypeName) || hasMacroPlumbing)
                if let unwrapped = unwrapPublished(child.value) {
                    childValue = unwrapped
                } else if PatchValueEncoder.isPublished(child.value) {
                    // BUG #9/#3: a `@Published` whose current value `unwrapPublished` could
                    // not reach (neither a settled `.value` NOR a `.publisher` subject with a
                    // readable `currentValue`). Encoding the raw `Published<…>` would marshal
                    // garbage `{"storage":…}`. SKIP it cleanly rather than corrupt the object.
                    // (The common `.assign(to:&$items)` / `$items.sink` MVVM case is NO LONGER
                    // skipped — `unwrapPublished` now reads the `.publisher` subject's live
                    // `currentValue`, so a populated collection marshals as a clean array.)
                    continue
                } else {
                    childValue = child.value
                }
                // SKIP-DON'T-FAIL (bug #6): a single unencodable SIBLING (a `Set<AnyCancellable>`,
                // a stored closure, a service reference, or a `.publisher`-state `@Published`)
                // must NOT zero out the WHOLE object. Before this fix, `encodeObject` returned
                // nil on the first unencodable child, so a reactive view-model holding e.g.
                // `var cancellables: Set<AnyCancellable>` alongside `var items: [Row]` marshalled
                // to `{}` — and a `ForEach(vm.items)` then read an EMPTY array, silently rendering
                // ZERO rows for a populated list. We now OMIT the unencodable field and keep the
                // encodable ones, so the data fields (the collection the body reads) survive. The
                // guest only ever reads fields the engine proved reconstructable; an omitted key
                // falls back to its guest-side default. The collection field itself is guaranteed
                // encodable by construction (the engine only registers a reactive collection whose
                // element type is scalar/flat-struct), so this never drops the NEEDED collection.
                guard let frag = encode(childValue, depth: depth + 1) else { continue }
                // Emit under the ONE name the guest scans (bug #47/#70): a wrapper/macro
                // backing field under its STRIPPED name (`items`), a plain underscored
                // field under its RAW source name (`_count`). A non-underscored field has
                // strippedKey == label, so this is just `label`.
                let emitKey = (label.hasPrefix("_") && !isWrapperBacking) ? label : strippedKey
                entries.append((emitKey, frag))
            }
            current = m.superclassMirror
        }
        // Stable key order; drop any duplicate (raw == stripped can't recur, but a
        // sibling could legitimately share the stripped name — keep the first).
        entries.sort { $0.0 < $1.0 }
        var seenKeys = Set<String>()
        let deduped = entries.filter { seenKeys.insert($0.0).inserted }
        return "{" + deduped.map { "\(PatchInstanceInputs.quotedJSONString($0.0)):\($0.1)" }
            .joined(separator: ",") + "}"
    }
}
#endif
