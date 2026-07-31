// SPDX-License-Identifier: MIT

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
        if let decimal = value as? Decimal {
            // Mirror reflects Decimal as its opaque `_mantissa` struct, which would
            // encode to semantically-unrecoverable JSON; emit a canonical numeric form.
            return PatchInstanceInputs.scalarJSONFragment((decimal as NSDecimalNumber).doubleValue)
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

        case .collection:
            return encodeArray(mirror, depth: depth)

        case .set:
            // A Set has no inherent order and Swift's hash seed is randomized per
            // process launch, so sort the encoded element fragments for stable,
            // cacheable output across launches. (The Array path must NOT sort — its
            // element order is load-bearing.)
            return encodeArray(mirror, depth: depth, sortElements: true)

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

    private static func encodeArray(_ mirror: Mirror, depth: Int, sortElements: Bool = false) -> String? {
        var parts: [String] = []
        for child in mirror.children {
            guard let frag = encode(child.value, depth: depth + 1) else { return nil }
            parts.append(frag)
        }
        if sortElements { parts.sort() }
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
        // Deterministic element order for stable, cacheable output (Dictionary hash
        // order is per-launch randomized, exactly like the object-key branch above).
        pairEntries.sort()
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
        // BUG R4-MED: the remaining fixed-width integer widths, matching
        // `scalarJSONFragment`. Without these a `[UInt64:V]`/`[Int8:V]` dictionary key was
        // non-stringy, so the dictionary fell to the `[[k,v],…]` pair form even though the
        // key has an unambiguous textual form (or, when the key also failed to encode as a
        // value, dropped the whole dictionary).
        case let i as Int8: return String(i)
        case let i as Int16: return String(i)
        case let u as UInt8: return String(u)
        case let u as UInt16: return String(u)
        case let u as UInt32: return String(u)
        case let u as UInt64: return String(u)
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
            // BUG R4-LOW: dedup the assembled keys. An associated value labelled literally
            // `case` (collides with the reserved envelope key) or a positional `_0` colliding
            // with a labelled `_0` (e.g. `foo(Int, _0: Int)`) would emit a JSON object with
            // DUPLICATE keys; the write-back/guest parsers (`JSONSerialization`) silently
            // collapse duplicates, dropping one associated value. We can't produce an
            // unambiguous shape, so return nil → the caller omits the key and the field falls
            // back to its guest-side default (demote-safe), exactly like an unencodable value.
            var seenKeys = Set<String>()
            for (k, _) in fields where !seenKeys.insert(k).inserted { return nil }
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

    /// The (emitKey → childValue) field set for an object, AFTER all of `encodeObject`'s
    /// selection rules (superclass walk, `_$` macro-plumbing skip, `_name` strip vs raw,
    /// `@Published` unwrap, label dedup). This is the SINGLE SOURCE OF TRUTH for which
    /// fields an object contributes and under what key — `encodeObject` encodes these and
    /// `PatchValueFingerprint.feedObject` fingerprints these, so the two can NEVER diverge
    /// on field selection (a divergence would let the fingerprint say "unchanged" while the
    /// marshalled field set differs — a stale-render hazard). It does NOT decide
    /// encodability of a field's VALUE (the caller does that, skipping a non-encodable /
    /// non-fingerprintable value identically on both sides). Returns the values in an
    /// insertion order that the caller sorts by key.
    ///
    /// Derives EVERYTHING from `mirror` (`.children` for the macro-plumbing probe, each
    /// child's `type(of:)` for the wrapper-type probe) — it never reads the top-level
    /// subject, so the encoder and fingerprint can both call it with just the mirror.
    static func objectFieldValues(mirror: Mirror) -> [(key: String, value: Any)] {
        // FAST PATH — the overwhelmingly common shape: a single-level struct/class (no
        // superclass) whose every field label is a PLAIN identifier (no leading `_`). Such an
        // object can have NO macro plumbing (`_$…` is underscored), no name-stripping, and no
        // emit-key collisions (a struct's own Mirror labels are unique), so none of the Set
        // bookkeeping / type probes below apply. Emitting the children directly avoids 2 Set
        // allocations + the per-child work — a real saving on a nested struct-array fingerprint
        // (each row hit this path). A single underscored OR inherited field falls to the full
        // path. Byte-identical output to the full path for this shape.
        if mirror.superclassMirror == nil {
            var simple: [(key: String, value: Any)] = []
            simple.reserveCapacity(mirror.children.count)
            var allPlain = true
            for child in mirror.children {
                guard let label = child.label, !label.isEmpty else { continue }
                if label.hasPrefix("_") { allPlain = false; break }
                simple.append((label, child.value))
            }
            if allPlain { return simple }
        }
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
        var entries: [(key: String, value: Any)] = []
        var current: Mirror? = mirror
        var seen = Set<String>()
        var emittedKeys = Set<String>()
        while let m = current {
            for child in m.children {
                guard let label = child.label, !label.isEmpty, !seen.contains(label) else { continue }
                // Skip macro-generated plumbing (`_$observationRegistrar`/`_$backingData`).
                if label.hasPrefix("_$") { seen.insert(label); continue }
                // BUG #47/#70: a SOURCE field literally named `_count`/`_id`; the CLI guest
                // scans the RAW source name (including the leading underscore).
                let strippedKey = label.hasPrefix("_") ? String(label.dropFirst()) : label
                guard !strippedKey.isEmpty else { continue }
                seen.insert(label)
                let childValue: Any
                let isUnderscored = label.hasPrefix("_")
                // BUG #47/#70 key choice (see encodeObject's history). The wrapper-type probe
                // (a per-child `String(describing: type(of:))`, which is NOT cheap) is only
                // consulted for an UNDERSCORED label — a plain `title`/`id` field can never be
                // wrapper-backing — so skip building the type-name string for the common
                // non-underscored field (this is on both the encode AND fingerprint hot path).
                let isWrapperBacking = isUnderscored
                    && (PatchValueEncoder.isPropertyWrapperTypeName(String(describing: type(of: child.value)))
                        || hasMacroPlumbing)
                // `@Published` unwrap only applies to an underscored backing field (`_x:
                // Published<X>`); a plain field is never `Published`, so skip the probe.
                if isUnderscored, let unwrapped = unwrapPublished(child.value) {
                    childValue = unwrapped
                } else if isUnderscored, PatchValueEncoder.isPublished(child.value) {
                    // BUG #9/#3: a `@Published` whose value can't be reached — skip cleanly.
                    continue
                } else {
                    childValue = child.value
                }
                let emitKey = (isUnderscored && !isWrapperBacking) ? label : strippedKey
                // Dedup the EMIT key (a sibling could legitimately share the stripped name —
                // keep the first). `encodeObject` previously deduped post-hoc; doing it here
                // keeps the field set the fingerprint sees identical to the one encoded.
                guard emittedKeys.insert(emitKey).inserted else { continue }
                entries.append((emitKey, childValue))
            }
            current = m.superclassMirror
        }
        return entries
    }

    private static func encodeObject(_ mirror: Mirror, depth: Int) -> String? {
        // SKIP-DON'T-FAIL (bug #6): a single unencodable SIBLING field must NOT zero out the
        // WHOLE object — omit it and keep the encodable ones. `objectFieldValues` already
        // applied the field-SELECTION rules; here we encode each selected value and drop a
        // non-encodable one (the fingerprint mirrors this exact skip).
        var entries: [(String, String)] = []
        for (emitKey, childValue) in PatchValueEncoder.objectFieldValues(mirror: mirror) {
            guard let frag = encode(childValue, depth: depth + 1) else { continue }
            entries.append((emitKey, frag))
        }
        // Stable key order (the field set is already emit-key-deduped in objectFieldValues).
        entries.sort { $0.0 < $1.0 }
        return "{" + entries.map { "\(PatchInstanceInputs.quotedJSONString($0.0)):\($0.1)" }
            .joined(separator: ",") + "}"
    }
}
#endif
