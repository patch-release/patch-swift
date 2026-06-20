// PatchValueFingerprint.swift — a CHEAP, COMPLETE change-detector for the marshalling
// hot path (P0 perf).
// =====================================================================================
// `PatchInstanceInputs.extract` Mirror-reflects a live view instance and recursively
// JSON-encodes every stored prop / property-wrapper value into the flat inputs JSON the
// lowered guest body reads — EVERY render. Profiling (RenderHotPathBenchmarkTests, RELEASE)
// shows the Mirror ENUMERATION itself is cheap (~3.8µs even for a rich 10-row-array
// instance) but the recursive JSON STRING-BUILDING (`PatchValueEncoder`) is the ~159µs
// cost. SwiftUI re-evaluates `body` constantly with UNCHANGED state, so re-building a
// byte-identical JSON string on every render is pure waste.
//
// This file provides the change-detector that lets `extract` SKIP the string build when
// the instance's marshalled state is unchanged since the last render: a fingerprint hash
// over EXACTLY the values `PatchValueEncoder` would encode, in the SAME traversal order.
// It costs ~Mirror-enumeration (no string allocation — just feeds bytes into a `Hasher`),
// so even when it can't skip the encode it adds only a few µs.
//
// CORRECTNESS (this is the #1 false-RENDER-risk area — a missed change = a STALE render =
// WRONG UI on device):
//   * The fingerprint walk PARALLELS `PatchValueEncoder.encode` case-for-case. It feeds the
//     Hasher the SAME scalar leaves the encoder would emit, plus a STRUCTURAL TAG at every
//     node (displayStyle discriminator + child count + labels + enum case name). So any
//     change the encoder would render differently — a scalar value, an array length, an
//     optional some↔none, an enum case, a dictionary key set, a reordering — changes the
//     fingerprint.
//   * REPRESENTABILITY MATCHES: the fingerprint returns `nil` for EXACTLY the values the
//     encoder returns `nil` for (depth overflow, an unrepresentable leaf, a malformed enum
//     payload, a dictionary whose value doesn't encode). A `nil` fingerprint means "cannot
//     cheaply+completely fingerprint" → the caller treats the instance as CHANGED and
//     re-marshals (the safe default — never a false "unchanged").
//   * The detector is therefore SOUND in the direction that matters: equal fingerprint ⇒
//     (overwhelmingly) equal marshalled JSON. The residual risk is a 64-bit `Hasher`
//     collision between two DISTINCT states of the SAME view's own data — astronomically
//     unlikely (Swift's per-process-seeded SipHash over the full leaf+structure content),
//     and it's the standard memoization tradeoff. We harden it by folding the field COUNT
//     and per-node structural tags into the hash so length/shape/reorder changes can't
//     collide on content alone.
//
// NOTE: this is intentionally a SEPARATE traversal from the encoder rather than reusing the
// encoder and hashing its output string — hashing the output string would require BUILDING
// the string (the exact ~159µs cost we're avoiding). The parallel-walk is the whole point.

#if canImport(SwiftUI)
import Foundation

/// Computes a content+structure fingerprint of a value, mirroring `PatchValueEncoder`'s
/// traversal so that an equal fingerprint implies equal marshalled JSON. Pure value
/// semantics: it only READS via Mirror (no allocation, no string building).
enum PatchValueFingerprint {

    /// Mirror the encoder's recursion bound exactly so representability matches.
    static let maxDepth = PatchValueEncoder.maxDepth

    /// Feed `value`'s content + structure into `hasher`. Returns false iff the value is
    /// NOT cheaply+completely fingerprintable (matches `PatchValueEncoder.encode` returning
    /// nil) — the caller then treats the whole instance as changed and re-marshals.
    /// `depth` guards recursion; callers start at 0.
    @discardableResult
    static func feed(_ value: Any, into hasher: inout Hasher, depth: Int = 0) -> Bool {
        if depth > maxDepth { return false }

        // 1) Scalars (+ String) — the encoder's fast path. Hash a per-kind discriminator
        //    PLUS the value so two scalars of different type/shape never alias, mirroring
        //    `scalarJSONFragment`'s exhaustive case list.
        if feedScalar(value, into: &hasher) { return true }

        // 2) Foundation leaf types with a canonical scalar wire form (mirror the encoder).
        if let date = value as? Date {
            hasher.combine(0x10 as UInt8); hasher.combine(date.timeIntervalSince1970); return true
        }
        if let uuid = value as? UUID {
            hasher.combine(0x11 as UInt8); hasher.combine(uuid); return true
        }
        if let url = value as? URL {
            hasher.combine(0x12 as UInt8); hasher.combine(url.absoluteString); return true
        }
        if let data = value as? Data {
            hasher.combine(0x13 as UInt8); hasher.combine(data); return true
        }
        if let decimal = value as? Decimal {
            hasher.combine(0x14 as UInt8)
            hasher.combine((decimal as NSDecimalNumber).doubleValue); return true
        }

        // 3) Structured values via Mirror — same dispatch as the encoder.
        let mirror = Mirror(reflecting: value)
        switch mirror.displayStyle {
        case .optional:
            hasher.combine(0x20 as UInt8)
            if let child = mirror.children.first {
                hasher.combine(1 as UInt8) // .some
                return feed(child.value, into: &hasher, depth: depth + 1)
            }
            hasher.combine(0 as UInt8) // .none
            return true

        case .collection:
            return feedArray(mirror, into: &hasher, depth: depth, sortElements: false)

        case .set:
            // The encoder SORTS a Set's element fragments for stable output, so the
            // fingerprint must be order-independent too — hash the per-element subhashes
            // SORTED (the encoder's `sortElements`).
            return feedArray(mirror, into: &hasher, depth: depth, sortElements: true)

        case .dictionary:
            return feedDictionary(mirror, into: &hasher, depth: depth)

        case .enum:
            return feedEnum(value, mirror: mirror, into: &hasher, depth: depth)

        case .struct, .class:
            return feedObject(value, mirror: mirror, into: &hasher, depth: depth)

        default:
            // .tuple / unknown — the encoder treats a non-empty one as an object, else nil.
            if mirror.children.isEmpty { return false }
            return feedObject(value, mirror: mirror, into: &hasher, depth: depth)
        }
    }

    /// Hash a supported scalar with a per-kind tag, mirroring `scalarJSONFragment`'s case
    /// list EXACTLY (so a value the encoder marshals as a scalar is fingerprinted as one,
    /// and a value it does NOT is left for the structured path / returns false). Integral
    /// `Double`/`Float`/`CGFloat` round to the same wire form as the encoder, so we hash the
    /// CANONICAL form (`doubleFingerprint`) to match (a `2.0` and a `2` Int still differ via
    /// the kind tag).
    private static func feedScalar(_ value: Any, into hasher: inout Hasher) -> Bool {
        switch value {
        case let s as String: hasher.combine(0x01 as UInt8); hasher.combine(s)
        case let b as Bool:   hasher.combine(0x02 as UInt8); hasher.combine(b)
        case let i as Int:    hasher.combine(0x03 as UInt8); hasher.combine(i)
        case let i as Int32:  hasher.combine(0x04 as UInt8); hasher.combine(i)
        case let i as Int64:  hasher.combine(0x05 as UInt8); hasher.combine(i)
        case let u as UInt:   hasher.combine(0x06 as UInt8); hasher.combine(u)
        case let i as Int8:   hasher.combine(0x07 as UInt8); hasher.combine(i)
        case let i as Int16:  hasher.combine(0x08 as UInt8); hasher.combine(i)
        case let u as UInt8:  hasher.combine(0x09 as UInt8); hasher.combine(u)
        case let u as UInt16: hasher.combine(0x0A as UInt8); hasher.combine(u)
        case let u as UInt32: hasher.combine(0x0B as UInt8); hasher.combine(u)
        case let u as UInt64: hasher.combine(0x0C as UInt8); hasher.combine(u)
        case let d as Double:  hasher.combine(0x0D as UInt8); feedDouble(d, into: &hasher)
        case let f as Float:   hasher.combine(0x0E as UInt8); feedDouble(Double(f), into: &hasher)
        case let c as CGFloat: hasher.combine(0x0F as UInt8); feedDouble(Double(c), into: &hasher)
        default: return false
        }
        return true
    }

    /// Hash a double in the SAME canonical form the encoder emits (an integral double prints
    /// as an Int; a non-finite prints as 0). So two values that marshal to the IDENTICAL JSON
    /// number fingerprint identically (and two that differ in wire form differ in fingerprint).
    private static func feedDouble(_ d: Double, into hasher: inout Hasher) {
        guard d.isFinite else { hasher.combine(0 as Int); hasher.combine(false); return }
        if d == d.rounded() && abs(d) < 1e15 {
            hasher.combine(Int(d)); hasher.combine(true)   // integral wire form
        } else {
            hasher.combine(d); hasher.combine(false)       // fractional wire form
        }
    }

    // MARK: - Aggregates (mirror the encoder)

    private static func feedArray(_ mirror: Mirror, into hasher: inout Hasher,
                                  depth: Int, sortElements: Bool) -> Bool {
        hasher.combine(sortElements ? (0x31 as UInt8) : (0x30 as UInt8))
        if sortElements {
            // Order-independent: subhash each element, sort the subhashes, fold them in.
            var subs: [UInt64] = []
            subs.reserveCapacity(mirror.children.count)
            for child in mirror.children {
                var h = Hasher()
                if !feed(child.value, into: &h, depth: depth + 1) { return false }
                subs.append(UInt64(bitPattern: Int64(h.finalize())))
            }
            subs.sort()
            hasher.combine(subs.count)
            for s in subs { hasher.combine(s) }
            return true
        }
        // Order-sensitive (Array): fold element subhashes in order, plus the count.
        var count = 0
        for child in mirror.children {
            if !feed(child.value, into: &hasher, depth: depth + 1) { return false }
            count += 1
        }
        hasher.combine(count)
        return true
    }

    private static func feedDictionary(_ mirror: Mirror, into hasher: inout Hasher,
                                       depth: Int) -> Bool {
        hasher.combine(0x40 as UInt8)
        // Order-independent (dictionary hash order is per-launch randomized; the encoder
        // sorts). Subhash each (key,value) pair, sort the subhashes, fold them in. This
        // is order-independent for BOTH the object-key form and the [[k,v],…] pair form
        // the encoder may choose — either way an equal key/value SET fingerprints equally.
        var subs: [UInt64] = []
        for child in mirror.children {
            let pair = Mirror(reflecting: child.value)
            let elems = Array(pair.children)
            guard elems.count == 2 else { return false }
            var h = Hasher()
            // Match the encoder's "value must encode" gate (it returns nil otherwise).
            if !feed(elems[1].value, into: &h, depth: depth + 1) { return false }
            // And it also requires the KEY to encode (the pair-form `keyFrag`).
            if !feed(elems[0].value, into: &h, depth: depth + 1) { return false }
            subs.append(UInt64(bitPattern: Int64(h.finalize())))
        }
        subs.sort()
        hasher.combine(subs.count)
        for s in subs { hasher.combine(s) }
        return true
    }

    // MARK: - Enum (mirror the encoder's case-name + payload handling)

    // We hash the case name + each payload element's LABEL + content. The encoder ALSO
    // returns nil on a rare dedup-key COLLISION (an associated value literally labelled
    // `case`, or a positional `_0` colliding with a labelled `_0`) — we do NOT replicate that
    // exact nil here, but it's SAFE: since we fold each element's distinct label, two states
    // the encoder renders differently always hash differently (no false HIT), and a state the
    // encoder omits is hashed self-consistently across renders (no stale reuse). The only
    // effect of the gap is a benign extra re-encode for such a contrived enum.
    private static func feedEnum(_ value: Any, mirror: Mirror, into hasher: inout Hasher,
                                 depth: Int) -> Bool {
        hasher.combine(0x50 as UInt8)
        if let child = mirror.children.first {
            let caseName = PatchValueEncoder.enumCaseName(value) ?? child.label ?? String(describing: value)
            hasher.combine(caseName)
            let payloadMirror = Mirror(reflecting: child.value)
            if payloadMirror.displayStyle == .tuple {
                hasher.combine(0x51 as UInt8)
                var i = 0
                for elem in payloadMirror.children {
                    let key = elem.label.flatMap { $0.hasPrefix(".") ? nil : $0 } ?? "_\(i)"
                    hasher.combine(key)
                    if !feed(elem.value, into: &hasher, depth: depth + 1) { return false }
                    i += 1
                }
                hasher.combine(i)
            } else {
                hasher.combine(0x52 as UInt8)
                if !feed(child.value, into: &hasher, depth: depth + 1) { return false }
            }
            return true
        }
        // No payload.
        let caseName = PatchValueEncoder.enumCaseName(value) ?? String(describing: value)
        hasher.combine(0x53 as UInt8)
        hasher.combine(caseName)
        return true
    }

    // MARK: - Struct / class (mirror `encodeObject` field selection EXACTLY)

    private static func feedObject(_ value: Any, mirror: Mirror, into hasher: inout Hasher,
                                   depth: Int) -> Bool {
        hasher.combine(0x60 as UInt8)
        // `encodeObject` SKIP-DON'T-FAILs an unencodable sibling field (it keeps the
        // encodable ones), so the OBJECT itself is always representable. The fingerprint
        // must mirror that: it walks the same children with the same skip rules, hashing
        // each field's emit-key + content, and SKIPS (does not fail on) a field that
        // doesn't fingerprint — so the per-field set hashed here matches the per-field set
        // the encoder emits. The whole object only fails on depth overflow (guarded above).
        _ = value // selection derives entirely from `mirror` (see objectFieldValues)
        // The encoder sorts entries by emit-key; sort the same way so insertion order can't
        // change the fingerprint. `objectFieldValues` is the SHARED field-selection source.
        let fields = PatchValueEncoder.objectFieldValues(mirror: mirror)
            .sorted { $0.key < $1.key }
        hasher.combine(fields.count)
        // Already in deterministic (sorted) key order — feed key+value DIRECTLY into the main
        // hasher (no per-field sub-Hasher/finalize, which dominated the cost on a struct array).
        for (key, childValue) in fields {
            hasher.combine(key)
            // A field whose value isn't fingerprintable mirrors `encodeObject` omitting a
            // non-encodable sibling: record a representability flag (so present-unrep ==
            // absent, exactly as the encoded JSON collapses them) and skip its content.
            let representable = feed(childValue, into: &hasher, depth: depth + 1)
            hasher.combine(representable)
        }
        return true
    }
}
#endif
