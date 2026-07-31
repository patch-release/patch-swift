// SPDX-License-Identifier: MIT

import Foundation

// ===========================================================================
// The generalized host-bridge TLV value format (DESIGN §2.2).
//
// This is the ONLY wire surface the engine must encode/decode against. It is a
// hand-rolled byte format (NO Codable / JSONEncoder / ICU) so a rewritten guest
// call can ride the embedded T0 tier; the host side here mirrors it exactly.
//
//   * A single value is one self-describing record:  [tag:u8][payload]
//   * An ARG blob   = [argc:u8] then `argc` records.
//   * A RESULT blob = exactly one record, OR empty (== void/nil).
//
// Byte layout (LITTLE-ENDIAN throughout — must match the proven prototype guest
// in experiments/host-bridge-generalized/guest):
//
//   tag | type   | payload
//   ----+--------+--------------------------------------------
//    0  | nil    | (none)
//    1  | i64    | 8 bytes LE (two's-complement)
//    2  | f64    | 8 bytes LE IEEE-754 bitpattern (finite-clamped, see below)
//    3  | bool   | 1 byte (0 / 1)
//    4  | string | [len:u32 LE][utf8 bytes]
//    5  | bytes  | [len:u32 LE][raw bytes]
//    6  | handle | 4 bytes LE Int32 (opaque native-object proxy)
//    7  | error  | [len:u32 LE][utf8 message] (host signalled failure → demote)
//
// FLOAT INVARIANT: a non-finite Double (NaN / ±Inf) is clamped to 0.0 BEFORE
// its bitpattern is written, matching the SDK's existing float invariant (e.g.
// DeviceInfoBridge's `guard d.isFinite else { return "0" }`). A non-finite float
// can never make it into a wire payload.
// ===========================================================================

/// The 8 TLV tags. Raw values are the on-wire tag bytes (0...7).
public enum TLVTag: UInt8, Sendable {
    case nilValue = 0
    case i64      = 1
    case f64      = 2
    case bool     = 3
    case string   = 4
    case bytes    = 5
    case handle   = 6
    case error    = 7
}

/// A single decoded/encodable TLV value. This is the cross-boundary value type:
/// a registered host thunk receives `[TLVValue]` args and returns one `TLVValue`.
public enum TLVValue: Sendable, Equatable {
    case nilValue
    case i64(Int64)
    case f64(Double)
    case bool(Bool)
    case string(String)
    case bytes([UInt8])
    case handle(Int32)
    /// A host-signalled failure. The engine's emitted wrapper treats ANY `.error`
    /// result as "demote this call to native".
    case error(String)

    /// The wire tag for this value.
    public var tag: TLVTag {
        switch self {
        case .nilValue: return .nilValue
        case .i64:      return .i64
        case .f64:      return .f64
        case .bool:     return .bool
        case .string:   return .string
        case .bytes:    return .bytes
        case .handle:   return .handle
        case .error:    return .error
        }
    }
}

/// Errors raised while decoding an untrusted arg blob (a malformed blob → a
/// tagged `.error` result → the caller demotes; never a crash).
public enum TLVDecodeError: Error, CustomStringConvertible, Equatable {
    case truncated(String)
    case badTag(UInt8)

    public var description: String {
        switch self {
        case .truncated(let w): return "TLV decode: truncated (\(w))"
        case .badTag(let t):    return "TLV decode: bad tag byte \(t)"
        }
    }
}

// MARK: - Encoder

/// Stateless TLV byte codec. All integers are little-endian.
public enum TLVCodec {

    // ---- little-endian scalar helpers ----

    @inline(__always)
    static func appendU32(_ v: UInt32, to buf: inout [UInt8]) {
        buf.append(UInt8(v & 0xff))
        buf.append(UInt8((v >> 8) & 0xff))
        buf.append(UInt8((v >> 16) & 0xff))
        buf.append(UInt8((v >> 24) & 0xff))
    }

    @inline(__always)
    static func appendU64(_ v: UInt64, to buf: inout [UInt8]) {
        var x = v
        for _ in 0..<8 {
            buf.append(UInt8(x & 0xff))
            x >>= 8
        }
    }

    /// The float invariant: a non-finite Double is clamped to 0.0 before its
    /// bitpattern is taken (matches the SDK's existing float-finite invariant).
    @inline(__always)
    static func finiteClamp(_ d: Double) -> Double { d.isFinite ? d : 0.0 }

    /// Encode ONE value as a single TLV record (the result-blob form).
    /// `.nilValue` encodes to an EMPTY blob — the packed-i64 `0` result the
    /// guest reads as void/nil, matching the prototype.
    public static func encodeValue(_ value: TLVValue) -> [UInt8] {
        var buf: [UInt8] = []
        switch value {
        case .nilValue:
            return []                                   // empty == void/nil
        case .i64(let v):
            buf.append(TLVTag.i64.rawValue)
            appendU64(UInt64(bitPattern: v), to: &buf)
        case .f64(let v):
            buf.append(TLVTag.f64.rawValue)
            appendU64(finiteClamp(v).bitPattern, to: &buf)
        case .bool(let v):
            buf.append(TLVTag.bool.rawValue)
            buf.append(v ? 1 : 0)
        case .handle(let v):
            buf.append(TLVTag.handle.rawValue)
            appendU32(UInt32(bitPattern: v), to: &buf)
        case .string(let s):
            let u = Array(s.utf8)
            buf.append(TLVTag.string.rawValue)
            appendU32(UInt32(u.count), to: &buf)
            buf.append(contentsOf: u)
        case .bytes(let b):
            buf.append(TLVTag.bytes.rawValue)
            appendU32(UInt32(b.count), to: &buf)
            buf.append(contentsOf: b)
        case .error(let s):
            let u = Array(s.utf8)
            buf.append(TLVTag.error.rawValue)
            appendU32(UInt32(u.count), to: &buf)
            buf.append(contentsOf: u)
        }
        return buf
    }

    /// Encode an ARG blob: `[argc:u8]` then one record per value. (Provided for
    /// symmetry / host-side test fixtures that synthesize an arg blob; the guest
    /// is the normal producer.) More than 255 args is unsupported by the `u8`
    /// argc field and is clamped — that is well beyond any real call.
    public static func encodeArgs(_ values: [TLVValue]) -> [UInt8] {
        var buf: [UInt8] = [UInt8(min(values.count, 255))]
        for v in values { buf.append(contentsOf: encodeValue(v)) }
        return buf
    }

    // MARK: - Decoder

    /// Decode an ARG blob (`[argc:u8]` + records) into its values. A malformed
    /// blob throws `TLVDecodeError` — the dispatcher turns that into a tagged
    /// `.error` result, never a crash.
    public static func decodeArgs(_ b: [UInt8]) throws -> [TLVValue] {
        guard !b.isEmpty else { return [] }
        var i = 0
        let argc = Int(b[i]); i += 1
        var out: [TLVValue] = []
        out.reserveCapacity(argc)
        for _ in 0..<argc {
            out.append(try decodeOneRecord(b, &i))
        }
        return out
    }

    /// Decode a RESULT blob (exactly one record, or empty == nil). Mainly for
    /// host-side tests asserting a round-trip; the guest is the normal consumer.
    public static func decodeResult(_ b: [UInt8]) throws -> TLVValue {
        guard !b.isEmpty else { return .nilValue }
        var i = 0
        return try decodeOneRecord(b, &i)
    }

    /// Decode a single record starting at `i`, advancing `i` past it.
    static func decodeOneRecord(_ b: [UInt8], _ i: inout Int) throws -> TLVValue {
        guard i < b.count else { throw TLVDecodeError.truncated("tag") }
        guard let tag = TLVTag(rawValue: b[i]) else { throw TLVDecodeError.badTag(b[i]) }
        i += 1

        func readU32() throws -> UInt32 {
            guard i + 4 <= b.count else { throw TLVDecodeError.truncated("u32") }
            let v = UInt32(b[i]) | (UInt32(b[i+1]) << 8)
                  | (UInt32(b[i+2]) << 16) | (UInt32(b[i+3]) << 24)
            i += 4
            return v
        }
        func readU64() throws -> UInt64 {
            guard i + 8 <= b.count else { throw TLVDecodeError.truncated("u64") }
            var v: UInt64 = 0
            for k in 0..<8 { v |= UInt64(b[i+k]) << (UInt64(k) * 8) }
            i += 8
            return v
        }
        func readBlob() throws -> [UInt8] {
            let n = Int(try readU32())
            guard i + n <= b.count else { throw TLVDecodeError.truncated("blob") }
            let slice = Array(b[i..<i+n]); i += n
            return slice
        }

        switch tag {
        case .nilValue:
            return .nilValue
        case .i64:
            return .i64(Int64(bitPattern: try readU64()))
        case .f64:
            return .f64(Double(bitPattern: try readU64()))
        case .bool:
            guard i < b.count else { throw TLVDecodeError.truncated("bool") }
            let v = b[i] != 0; i += 1
            return .bool(v)
        case .handle:
            return .handle(Int32(bitPattern: try readU32()))
        case .string:
            return .string(String(decoding: try readBlob(), as: UTF8.self))
        case .bytes:
            return .bytes(try readBlob())
        case .error:
            return .error(String(decoding: try readBlob(), as: UTF8.self))
        }
    }
}

// MARK: - Typed argument accessors (what a registered thunk uses)

/// A type-checking reader over a decoded arg list. A thunk pulls its typed args
/// out of this; any type/arity mismatch THROWS, which the dispatcher converts to
/// a tagged `.error` result (→ the caller demotes). This is the host-side
/// analogue of the prototype's `Array<HostValue>` accessor extension, made a
/// first-class type so the public registration API is clean.
public struct ArgReader {
    public let values: [TLVValue]
    public init(_ values: [TLVValue]) { self.values = values }

    public var count: Int { values.count }

    /// Errors a thunk raises pulling typed args (mapped to a `.error` result).
    public enum ArgError: Error, CustomStringConvertible, Equatable {
        case arity(expected: Int, got: Int)
        case wrongType(index: Int, expected: String)
        case indexOutOfRange(index: Int)
        public var description: String {
            switch self {
            case .arity(let e, let g): return "arg arity: expected \(e), got \(g)"
            case .wrongType(let i, let e): return "arg \(i): expected \(e)"
            case .indexOutOfRange(let i): return "arg \(i): out of range"
            }
        }
    }

    /// Assert exactly `n` arguments (a thunk's first line, typically).
    public func requireArity(_ n: Int) throws {
        guard values.count == n else { throw ArgError.arity(expected: n, got: values.count) }
    }

    @inline(__always)
    private func at(_ i: Int) throws -> TLVValue {
        guard i >= 0, i < values.count else { throw ArgError.indexOutOfRange(index: i) }
        return values[i]
    }

    /// A Double. An `i64` arg is accepted and widened (a common engine shape:
    /// an integer literal passed where the native param is a Double).
    public func f64(_ i: Int) throws -> Double {
        switch try at(i) {
        case .f64(let v): return v
        case .i64(let v): return Double(v)
        default: throw ArgError.wrongType(index: i, expected: "f64")
        }
    }

    /// An Int64. (Use `Int(reader.i64(0))` for an `Int` param.)
    public func i64(_ i: Int) throws -> Int64 {
        guard case .i64(let v) = try at(i) else { throw ArgError.wrongType(index: i, expected: "i64") }
        return v
    }

    public func bool(_ i: Int) throws -> Bool {
        guard case .bool(let v) = try at(i) else { throw ArgError.wrongType(index: i, expected: "bool") }
        return v
    }

    public func string(_ i: Int) throws -> String {
        guard case .string(let v) = try at(i) else { throw ArgError.wrongType(index: i, expected: "string") }
        return v
    }

    public func bytes(_ i: Int) throws -> [UInt8] {
        guard case .bytes(let v) = try at(i) else { throw ArgError.wrongType(index: i, expected: "bytes") }
        return v
    }

    /// A raw handle id (the opaque Int32). Usually you want `object(_:as:_:)`.
    public func handle(_ i: Int) throws -> Int32 {
        guard case .handle(let v) = try at(i) else { throw ArgError.wrongType(index: i, expected: "handle") }
        return v
    }

    public func isNil(_ i: Int) throws -> Bool {
        if case .nilValue = try at(i) { return true }
        return false
    }
}
