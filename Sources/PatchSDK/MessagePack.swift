import Foundation

// A small, dependency-free MessagePack implementation used to marshal arbitrary
// `Codable` values across the host <-> WASM boundary as a compact byte blob.
//
// Why hand-rolled rather than an SPM dependency: PatchSDK must build and run
// unchanged on iOS (device + simulator). A vendored, pure-Swift codec with zero
// native-only dependencies is the safest choice — it relies only on
// `Foundation`'s `Encoder`/`Decoder` protocols and `Data`, which exist on every
// Apple platform. (Note: the *guest* WASM module typically uses
// JSONEncoder/JSONDecoder — see poc/wasm-compilation — so generated bridges may
// translate; the host-side codec here is the SDK's canonical structured-blob
// format and round-trips with itself.)
//
// Spec coverage: the subset needed for Codable payloads — nil, bool, ints
// (pos/neg fixint + int8/16/32/64, uint8/16/32/64), float32/float64, str
// (fixstr/str8/16/32), bin (bin8/16/32), array (fixarray/array16/32), map
// (fixmap/map16/32). This is the canonical MessagePack wire format
// (https://github.com/msgpack/msgpack/blob/master/spec.md).

// MARK: - Public façade

public enum MessagePack {
    /// Encode any `Encodable` value to MessagePack bytes.
    public static func encode<T: Encodable>(_ value: T) throws -> [UInt8] {
        let encoder = MessagePackEncoder()
        return try encoder.encode(value)
    }

    /// Decode a MessagePack byte blob into a `Decodable` value.
    public static func decode<T: Decodable>(_ type: T.Type, from bytes: [UInt8]) throws -> T {
        let decoder = MessagePackDecoder()
        return try decoder.decode(type, from: bytes)
    }
}

// MARK: - Intermediate value tree
//
// We Codable-encode/decode into a `MPValue` tree, then (de)serialize the tree to
// bytes. This keeps the Encoder/Decoder containers simple and the wire writer
// isolated and testable.

enum MPValue {
    case `nil`
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case double(Double)
    case string(String)
    case binary([UInt8])
    case array([MPValue])
    case map([(MPValue, MPValue)])
}

public struct MessagePackError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { "MessagePack error: \(message)" }
}

// MARK: - Wire serialization

enum MPWriter {
    static func write(_ value: MPValue) -> [UInt8] {
        var out: [UInt8] = []
        encode(value, into: &out)
        return out
    }

    private static func encode(_ value: MPValue, into out: inout [UInt8]) {
        switch value {
        case .nil: out.append(0xc0)
        case .bool(let b): out.append(b ? 0xc3 : 0xc2)
        case .int(let i): encodeInt(i, into: &out)
        case .uint(let u): encodeUInt(u, into: &out)
        case .double(let d):
            out.append(0xcb)
            appendBE(d.bitPattern, into: &out)
        case .string(let s): encodeString(s, into: &out)
        case .binary(let b): encodeBinary(b, into: &out)
        case .array(let a):
            encodeContainerHeader(count: a.count, fix: 0x90, n16: 0xdc, n32: 0xdd, into: &out)
            for el in a { encode(el, into: &out) }
        case .map(let m):
            encodeContainerHeader(count: m.count, fix: 0x80, n16: 0xde, n32: 0xdf, into: &out)
            for (k, v) in m { encode(k, into: &out); encode(v, into: &out) }
        }
    }

    private static func encodeInt(_ i: Int64, into out: inout [UInt8]) {
        if i >= 0 { encodeUInt(UInt64(i), into: &out); return }
        if i >= -32 { out.append(UInt8(bitPattern: Int8(truncatingIfNeeded: i))); return } // neg fixint
        if i >= -128 { out.append(0xd0); out.append(UInt8(bitPattern: Int8(truncatingIfNeeded: i))); return }
        if i >= -32768 { out.append(0xd1); appendBE(UInt16(bitPattern: Int16(truncatingIfNeeded: i)), into: &out); return }
        if i >= -2147483648 { out.append(0xd2); appendBE(UInt32(bitPattern: Int32(truncatingIfNeeded: i)), into: &out); return }
        out.append(0xd3); appendBE(UInt64(bitPattern: i), into: &out)
    }

    private static func encodeUInt(_ u: UInt64, into out: inout [UInt8]) {
        if u <= 0x7f { out.append(UInt8(u)); return }            // pos fixint
        if u <= 0xff { out.append(0xcc); out.append(UInt8(u)); return }
        if u <= 0xffff { out.append(0xcd); appendBE(UInt16(u), into: &out); return }
        if u <= 0xffff_ffff { out.append(0xce); appendBE(UInt32(u), into: &out); return }
        out.append(0xcf); appendBE(u, into: &out)
    }

    private static func encodeString(_ s: String, into out: inout [UInt8]) {
        let bytes = [UInt8](s.utf8)
        let n = bytes.count
        if n < 32 { out.append(0xa0 | UInt8(n)) }
        else if n <= 0xff { out.append(0xd9); out.append(UInt8(n)) }
        else if n <= 0xffff { out.append(0xda); appendBE(UInt16(n), into: &out) }
        else { out.append(0xdb); appendBE(UInt32(n), into: &out) }
        out.append(contentsOf: bytes)
    }

    private static func encodeBinary(_ b: [UInt8], into out: inout [UInt8]) {
        let n = b.count
        if n <= 0xff { out.append(0xc4); out.append(UInt8(n)) }
        else if n <= 0xffff { out.append(0xc5); appendBE(UInt16(n), into: &out) }
        else { out.append(0xc6); appendBE(UInt32(n), into: &out) }
        out.append(contentsOf: b)
    }

    private static func encodeContainerHeader(
        count: Int, fix: UInt8, n16: UInt8, n32: UInt8, into out: inout [UInt8]
    ) {
        if count < 16 { out.append(fix | UInt8(count)) }
        else if count <= 0xffff { out.append(n16); appendBE(UInt16(count), into: &out) }
        else { out.append(n32); appendBE(UInt32(count), into: &out) }
    }

    private static func appendBE<T: FixedWidthInteger>(_ v: T, into out: inout [UInt8]) {
        let big = v.bigEndian
        withUnsafeBytes(of: big) { out.append(contentsOf: $0) }
    }
}

// MARK: - Wire deserialization

struct MPReader {
    let bytes: [UInt8]
    var i = 0
    /// Current container-nesting depth, bounded to stop a hostile/corrupt blob
    /// of deeply-nested arrays/maps from blowing the native stack (SIGSEGV — an
    /// uncatchable crash, not a thrown error). 1024 is far past any real payload
    /// the engine emits while keeping the recursive descent within a safe stack.
    private var depth = 0
    static let maxDepth = 1024

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func read() throws -> MPValue {
        let b = try byte()
        switch b {
        case 0x00...0x7f: return .uint(UInt64(b))             // pos fixint
        case 0xe0...0xff: return .int(Int64(Int8(bitPattern: b))) // neg fixint
        case 0x80...0x8f: return try readMap(Int(b & 0x0f))   // fixmap
        case 0x90...0x9f: return try readArray(Int(b & 0x0f)) // fixarray
        case 0xa0...0xbf: return try readStr(Int(b & 0x1f))   // fixstr
        case 0xc0: return .nil
        case 0xc2: return .bool(false)
        case 0xc3: return .bool(true)
        case 0xc4: return .binary(try readBytes(Int(try byte())))
        case 0xc5: return .binary(try readBytes(Int(try u16())))
        case 0xc6: return .binary(try readBytes(Int(try u32())))
        case 0xca: return .double(Double(Float(bitPattern: try u32())))
        case 0xcb: return .double(Double(bitPattern: try u64()))
        case 0xcc: return .uint(UInt64(try byte()))
        case 0xcd: return .uint(UInt64(try u16()))
        case 0xce: return .uint(UInt64(try u32()))
        case 0xcf: return .uint(try u64())
        case 0xd0: return .int(Int64(Int8(bitPattern: try byte())))
        case 0xd1: return .int(Int64(Int16(bitPattern: try u16())))
        case 0xd2: return .int(Int64(Int32(bitPattern: try u32())))
        case 0xd3: return .int(Int64(bitPattern: try u64()))
        case 0xd9: return try readStr(Int(try byte()))
        case 0xda: return try readStr(Int(try u16()))
        case 0xdb: return try readStr(Int(try u32()))
        case 0xdc: return try readArray(Int(try u16()))
        case 0xdd: return try readArray(Int(try u32()))
        case 0xde: return try readMap(Int(try u16()))
        case 0xdf: return try readMap(Int(try u32()))
        default: throw MessagePackError("unsupported MessagePack tag 0x\(String(b, radix: 16))")
        }
    }

    private mutating func byte() throws -> UInt8 {
        guard i < bytes.count else { throw MessagePackError("unexpected end of input") }
        defer { i += 1 }
        return bytes[i]
    }
    private mutating func readBytes(_ n: Int) throws -> [UInt8] {
        guard i + n <= bytes.count else { throw MessagePackError("truncated payload") }
        defer { i += n }
        return [UInt8](bytes[i..<(i + n)])
    }
    private mutating func u16() throws -> UInt16 { try beInt() }
    private mutating func u32() throws -> UInt32 { try beInt() }
    private mutating func u64() throws -> UInt64 { try beInt() }
    private mutating func beInt<T: FixedWidthInteger>() throws -> T {
        let size = MemoryLayout<T>.size
        let raw = try readBytes(size)
        var v: T = 0
        for b in raw { v = (v << 8) | T(b) }
        return v
    }
    private mutating func readStr(_ n: Int) throws -> MPValue {
        .string(String(decoding: try readBytes(n), as: UTF8.self))
    }
    private mutating func readArray(_ n: Int) throws -> MPValue {
        // A declared count is attacker-controlled (str/array/map32 carry a u32 up
        // to ~4.29B). Each element occupies at least one byte, so a count greater
        // than the bytes left can never be satisfied — reject it BEFORE reserving
        // capacity, so a corrupt/hostile blob can't trigger a multi-GB allocation
        // (OOM crash) on `reserveCapacity`.
        guard n >= 0, n <= bytes.count - i else { throw MessagePackError("array count exceeds remaining input") }
        try enterContainer(); defer { depth -= 1 }
        var arr: [MPValue] = []; arr.reserveCapacity(n)
        for _ in 0..<n { arr.append(try read()) }
        return .array(arr)
    }
    private mutating func readMap(_ n: Int) throws -> MPValue {
        // Each map entry needs >= 2 bytes (a key + a value), so a count above
        // (remaining / 2) is unsatisfiable — reject before reserving to avoid an
        // OOM allocation on a malformed/hostile count.
        guard n >= 0, n <= (bytes.count - i) / 2 else { throw MessagePackError("map count exceeds remaining input") }
        try enterContainer(); defer { depth -= 1 }
        var pairs: [(MPValue, MPValue)] = []; pairs.reserveCapacity(n)
        for _ in 0..<n { pairs.append((try read(), try read())) }
        return .map(pairs)
    }

    /// Increment container-nesting depth, rejecting input that nests past the
    /// limit. Throwing here turns a would-be stack overflow into a clean error.
    private mutating func enterContainer() throws {
        depth += 1
        guard depth <= Self.maxDepth else {
            throw MessagePackError("nesting depth exceeds \(Self.maxDepth)")
        }
    }
}
