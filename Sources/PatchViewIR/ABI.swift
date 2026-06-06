// ABI.swift — the wire envelope + packed-(ptr,len) helpers shared by guest+host.
//
// The guest's lowered body export has the engine's canonical signature
// `view_body(ptr: i32, len: i32) -> i64`:
//   * the host writes a JSON "inputs" blob (state/inputs marshalled in) at ptr,
//   * the guest builds a `ViewNode` tree, JSON-encodes it into a fresh
//     `patch_malloc`'d buffer, and returns the packed `(outPtr<<32)|outLen`.
// This matches `Patch.callPacked` / `callJSON` (sdk Patch.swift) exactly, so the
// real SDK can drive a frontier module with no new host primitive.

import Foundation

// `BodyEmission` itself lives in BodyEmission.swift (Foundation-free, so it
// compiles into the embedded guest). This file adds only the Foundation-backed
// JSON codec used by the host + the T2 (full-Foundation) guest.

public enum ViewNodeWire {
    /// Encode a `BodyEmission` to JSON bytes (the boundary format).
    public static func encode(_ emission: BodyEmission) throws -> [UInt8] {
        [UInt8](try JSONEncoder().encode(emission))
    }
    /// Decode JSON bytes back into a `BodyEmission`.
    public static func decode(_ bytes: [UInt8]) throws -> BodyEmission {
        try JSONDecoder().decode(BodyEmission.self, from: Data(bytes))
    }

    // MARK: - Interactive dispatch

    /// Encode the `{state, event}` the host sends to the guest's `dispatch`.
    ///
    /// `state` is the guest's own opaque state JSON, carried end-to-end as a JSON
    /// STRING value (the host stores + forwards the exact string the guest last
    /// returned; it never interprets it). The guest parses that string back into
    /// its typed State. This keeps the host fully decoupled from the State type.
    public static func encodeDispatch(state: String, event: DispatchEvent) throws -> [UInt8] {
        struct Envelope: Codable { var state: String; var event: DispatchEvent }
        return [UInt8](try JSONEncoder().encode(Envelope(state: state, event: event)))
    }

    /// Decode the `{state, tree, coverage?}` the guest returns from `dispatch`.
    public static func decodeDispatch(_ bytes: [UInt8]) throws -> DispatchResult {
        try JSONDecoder().decode(DispatchResult.self, from: Data(bytes))
    }
}
