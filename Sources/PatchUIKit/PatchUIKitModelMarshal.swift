// PatchUIKitModelMarshal.swift — marshal a cell's MODEL value to the flat inputs
// JSON the lowered guest construction scans.
// =============================================================================
// The UIKit analogue of `PatchInstanceInputs` (SwiftUI). A cell model is a flat
// value type (`struct CellModel { let title: String; let subtitle: String }`); this
// reflects its top-level stored properties into `{"title":"…","subtitle":"…"}` so the
// guest's `_patchScanString("title")` etc. read the REAL values. The engine flattened
// the model fields to top-level keys (stripping the `model.` prefix), so the keys here
// are the bare field names — matching the guest's bindings.
//
// Only flat scalars + scalar arrays marshal (the kinds the guest reconstructs); a
// nested struct/enum field makes the cell `referencesUnmarshalledInput` upstream (so
// it's never auto-routed), so dropping it here is safe. Mirror-based, no Codable
// requirement on the model.
//
// UIKit-FREE (pure Foundation + CoreGraphics) so it compiles + is unit-tested on the
// headless macOS CI host too — the marshalling is the platform-independent core.

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public enum PatchUIKitModelMarshal {
    /// Reflect `model`'s top-level stored properties into a flat JSON object. A model
    /// that is itself a scalar (rare) marshals to an empty object (the construction
    /// reads no fields). Property-wrapper backing names (`_x`) are unwrapped to `x`.
    public static func flatJSON(from model: Any) -> String {
        var fragments: [(key: String, json: String)] = []
        let mirror = Mirror(reflecting: model)
        // A model passed as `Any?` that's actually nil reflects as `Optional.none`.
        if mirror.displayStyle == .optional {
            guard let inner = mirror.children.first?.value else { return "{}" }
            return flatJSON(from: inner)
        }
        for child in mirror.children {
            guard var label = child.label else { continue }
            if label.hasPrefix("_") { label = String(label.dropFirst()) }
            guard !label.isEmpty, let frag = fragment(for: child.value) else { continue }
            fragments.append((label, frag))
        }
        fragments.sort { $0.key < $1.key }
        return "{" + fragments.map { "\(quoted($0.key)):\($0.json)" }.joined(separator: ",") + "}"
    }

    /// A JSON fragment for a supported scalar / scalar array, else nil (dropped).
    static func fragment(for value: Any) -> String? {
        switch value {
        case let s as String: return quoted(s)
        case let b as Bool: return b ? "true" : "false"
        case let i as Int: return String(i)
        case let i as Int32: return String(i)
        case let i as Int64: return String(i)
        case let u as UInt: return String(u)
        case let d as Double: return numFragment(d)
        case let f as Float: return numFragment(Double(f))
        #if canImport(CoreGraphics)
        case let c as CGFloat: return numFragment(Double(c))
        #endif
        case let arr as [String]: return "[" + arr.map(quoted).joined(separator: ",") + "]"
        case let arr as [Int]: return "[" + arr.map(String.init).joined(separator: ",") + "]"
        case let arr as [Double]: return "[" + arr.map(numFragment).joined(separator: ",") + "]"
        case let arr as [Bool]: return "[" + arr.map { $0 ? "true" : "false" }.joined(separator: ",") + "]"
        default:
            // An Optional scalar: unwrap one level (`String?` → its String, or drop nil).
            let m = Mirror(reflecting: value)
            if m.displayStyle == .optional {
                guard let inner = m.children.first?.value else { return nil }
                return fragment(for: inner)
            }
            return nil
        }
    }

    static func numFragment(_ d: Double) -> String {
        guard d.isFinite else { return "0" }
        if d == d.rounded() && abs(d) < 1e15 { return String(Int(d)) }
        return String(d)
    }

    static func quoted(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            case let c where c.value < 0x20: out += String(format: "\\u%04x", c.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
