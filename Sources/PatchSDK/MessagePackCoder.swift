import Foundation

// Codable Encoder/Decoder that bridge Swift values to/from the `MPValue` tree,
// which `MPWriter`/`MPReader` serialize to MessagePack bytes. Kept deliberately
// small: keyed + unkeyed + single-value containers, the cases Codable actually
// emits. Pure Swift/Foundation; iOS-safe.

// MARK: - Encoder

final class MessagePackEncoder {
    func encode<T: Encodable>(_ value: T) throws -> [UInt8] {
        let enc = _MPEncoder()
        try value.encode(to: enc)
        return MPWriter.write(enc.value ?? .nil)
    }
}

private final class _MPEncoder: Encoder {
    var codingPath: [CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] = [:]

    /// A concrete value set by a single-value container.
    private var directValue: MPValue?
    /// A lazy resolver installed by a keyed/unkeyed container. Resolved on read
    /// (after all nested writes have happened) so a nested container that is
    /// populated *after* it is requested is captured correctly. (Resolving
    /// eagerly when the nested container is handed back captures it while still
    /// empty — the bug this replaces, which silently dropped nested contents.)
    private var valueResolver: (() -> MPValue)?

    /// The encoded value, resolving any installed container resolver lazily.
    var value: MPValue? {
        if let valueResolver { return valueResolver() }
        return directValue
    }

    func setDirect(_ v: MPValue) { directValue = v; valueResolver = nil }
    func setResolver(_ r: @escaping () -> MPValue) { valueResolver = r; directValue = nil }

    init(codingPath: [CodingKey] = []) { self.codingPath = codingPath }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        let c = _MPKeyedEncoding<Key>(encoder: self, codingPath: codingPath)
        return KeyedEncodingContainer(c)
    }
    func unkeyedContainer() -> UnkeyedEncodingContainer {
        _MPUnkeyedEncoding(encoder: self, codingPath: codingPath)
    }
    func singleValueContainer() -> SingleValueEncodingContainer {
        _MPSingleValueEncoding(encoder: self, codingPath: codingPath)
    }

    // Encode a nested value, returning its MPValue.
    func encodeNested<T: Encodable>(_ v: T, codingPath: [CodingKey]) throws -> MPValue {
        // Foundation types with bespoke wire forms.
        if let data = v as? Data { return .binary([UInt8](data)) }
        if let date = v as? Date { return .double(date.timeIntervalSince1970) }
        let sub = _MPEncoder(codingPath: codingPath)
        try v.encode(to: sub)
        return sub.value ?? .nil
    }
}

private struct _MPKeyedEncoding<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let encoder: _MPEncoder
    var codingPath: [CodingKey]
    // Preserve insertion order so output is deterministic. Each value is stored
    // as a *resolver* closure so a nested container (handed back empty and
    // populated afterwards) is read at serialization time, not when requested.
    final class Box { var pairs: [(MPValue, () -> MPValue)] = [] }
    let box = Box()

    init(encoder: _MPEncoder, codingPath: [CodingKey]) {
        self.encoder = encoder
        self.codingPath = codingPath
        // Mark as a map (even if empty) and install a resolver that materializes
        // every pair lazily on read.
        let box = self.box
        encoder.setResolver { .map(box.pairs.map { ($0.0, $0.1()) }) }
    }

    private func set(_ key: Key, _ value: MPValue) {
        box.pairs.append((.string(key.stringValue), { value }))
    }
    private func setLazy(_ key: Key, _ resolve: @escaping () -> MPValue) {
        box.pairs.append((.string(key.stringValue), resolve))
    }

    mutating func encodeNil(forKey key: Key) throws { set(key, .nil) }
    mutating func encode(_ v: Bool, forKey key: Key) throws { set(key, .bool(v)) }
    mutating func encode(_ v: String, forKey key: Key) throws { set(key, .string(v)) }
    mutating func encode(_ v: Double, forKey key: Key) throws { set(key, .double(v)) }
    mutating func encode(_ v: Float, forKey key: Key) throws { set(key, .double(Double(v))) }
    mutating func encode(_ v: Int, forKey key: Key) throws { set(key, .int(Int64(v))) }
    mutating func encode(_ v: Int8, forKey key: Key) throws { set(key, .int(Int64(v))) }
    mutating func encode(_ v: Int16, forKey key: Key) throws { set(key, .int(Int64(v))) }
    mutating func encode(_ v: Int32, forKey key: Key) throws { set(key, .int(Int64(v))) }
    mutating func encode(_ v: Int64, forKey key: Key) throws { set(key, .int(v)) }
    mutating func encode(_ v: UInt, forKey key: Key) throws { set(key, .uint(UInt64(v))) }
    mutating func encode(_ v: UInt8, forKey key: Key) throws { set(key, .uint(UInt64(v))) }
    mutating func encode(_ v: UInt16, forKey key: Key) throws { set(key, .uint(UInt64(v))) }
    mutating func encode(_ v: UInt32, forKey key: Key) throws { set(key, .uint(UInt64(v))) }
    mutating func encode(_ v: UInt64, forKey key: Key) throws { set(key, .uint(v)) }
    mutating func encode<T: Encodable>(_ v: T, forKey key: Key) throws {
        set(key, try encoder.encodeNested(v, codingPath: codingPath + [key]))
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type, forKey key: Key
    ) -> KeyedEncodingContainer<NestedKey> {
        let sub = _MPEncoder(codingPath: codingPath + [key])
        let c = _MPKeyedEncoding<NestedKey>(encoder: sub, codingPath: sub.codingPath)
        // Register the sub-encoder's value as a RESOLVER read lazily at
        // serialization time — the caller populates `c` *after* this returns, so
        // reading `sub.value` now would capture an empty map.
        setLazy(key, { sub.value ?? .map([]) })
        return KeyedEncodingContainer(c)
    }
    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        let sub = _MPEncoder(codingPath: codingPath + [key])
        let c = _MPUnkeyedEncoding(encoder: sub, codingPath: sub.codingPath)
        setLazy(key, { sub.value ?? .array([]) })
        return c
    }
    mutating func superEncoder() -> Encoder { encoder }
    mutating func superEncoder(forKey key: Key) -> Encoder { encoder }
}

private struct _MPUnkeyedEncoding: UnkeyedEncodingContainer {
    let encoder: _MPEncoder
    var codingPath: [CodingKey]
    // Each item is a resolver closure (read lazily at serialization time) so a
    // nested container populated after it is requested is captured correctly.
    final class Box { var items: [() -> MPValue] = [] }
    let box = Box()
    var count: Int { box.items.count }

    init(encoder: _MPEncoder, codingPath: [CodingKey]) {
        self.encoder = encoder
        self.codingPath = codingPath
        let box = self.box
        encoder.setResolver { .array(box.items.map { $0() }) }
    }

    private func append(_ v: MPValue) {
        box.items.append({ v })
    }
    private func appendLazy(_ resolve: @escaping () -> MPValue) {
        box.items.append(resolve)
    }

    mutating func encodeNil() throws { append(.nil) }
    mutating func encode(_ v: Bool) throws { append(.bool(v)) }
    mutating func encode(_ v: String) throws { append(.string(v)) }
    mutating func encode(_ v: Double) throws { append(.double(v)) }
    mutating func encode(_ v: Float) throws { append(.double(Double(v))) }
    mutating func encode(_ v: Int) throws { append(.int(Int64(v))) }
    mutating func encode(_ v: Int8) throws { append(.int(Int64(v))) }
    mutating func encode(_ v: Int16) throws { append(.int(Int64(v))) }
    mutating func encode(_ v: Int32) throws { append(.int(Int64(v))) }
    mutating func encode(_ v: Int64) throws { append(.int(v)) }
    mutating func encode(_ v: UInt) throws { append(.uint(UInt64(v))) }
    mutating func encode(_ v: UInt8) throws { append(.uint(UInt64(v))) }
    mutating func encode(_ v: UInt16) throws { append(.uint(UInt64(v))) }
    mutating func encode(_ v: UInt32) throws { append(.uint(UInt64(v))) }
    mutating func encode(_ v: UInt64) throws { append(.uint(v)) }
    mutating func encode<T: Encodable>(_ v: T) throws {
        append(try encoder.encodeNested(v, codingPath: codingPath))
    }
    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type
    ) -> KeyedEncodingContainer<NestedKey> {
        let sub = _MPEncoder(codingPath: codingPath)
        let c = _MPKeyedEncoding<NestedKey>(encoder: sub, codingPath: sub.codingPath)
        appendLazy({ sub.value ?? .map([]) })
        return KeyedEncodingContainer(c)
    }
    mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        let sub = _MPEncoder(codingPath: codingPath)
        let c = _MPUnkeyedEncoding(encoder: sub, codingPath: sub.codingPath)
        appendLazy({ sub.value ?? .array([]) })
        return c
    }
    mutating func superEncoder() -> Encoder { encoder }
}

private struct _MPSingleValueEncoding: SingleValueEncodingContainer {
    let encoder: _MPEncoder
    var codingPath: [CodingKey]

    mutating func encodeNil() throws { encoder.setDirect(.nil) }
    mutating func encode(_ v: Bool) throws { encoder.setDirect(.bool(v)) }
    mutating func encode(_ v: String) throws { encoder.setDirect(.string(v)) }
    mutating func encode(_ v: Double) throws { encoder.setDirect(.double(v)) }
    mutating func encode(_ v: Float) throws { encoder.setDirect(.double(Double(v))) }
    mutating func encode(_ v: Int) throws { encoder.setDirect(.int(Int64(v))) }
    mutating func encode(_ v: Int8) throws { encoder.setDirect(.int(Int64(v))) }
    mutating func encode(_ v: Int16) throws { encoder.setDirect(.int(Int64(v))) }
    mutating func encode(_ v: Int32) throws { encoder.setDirect(.int(Int64(v))) }
    mutating func encode(_ v: Int64) throws { encoder.setDirect(.int(v)) }
    mutating func encode(_ v: UInt) throws { encoder.setDirect(.uint(UInt64(v))) }
    mutating func encode(_ v: UInt8) throws { encoder.setDirect(.uint(UInt64(v))) }
    mutating func encode(_ v: UInt16) throws { encoder.setDirect(.uint(UInt64(v))) }
    mutating func encode(_ v: UInt32) throws { encoder.setDirect(.uint(UInt64(v))) }
    mutating func encode(_ v: UInt64) throws { encoder.setDirect(.uint(v)) }
    mutating func encode<T: Encodable>(_ v: T) throws {
        encoder.setDirect(try encoder.encodeNested(v, codingPath: codingPath))
    }
}

// MARK: - Decoder

final class MessagePackDecoder {
    func decode<T: Decodable>(_ type: T.Type, from bytes: [UInt8]) throws -> T {
        var reader = MPReader(bytes)
        let tree = try reader.read()
        let dec = _MPDecoder(value: tree)
        return try T(from: dec)
    }
}

private struct _MPDecoder: Decoder {
    let value: MPValue
    var codingPath: [CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] = [:]

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard case .map(let pairs) = value else {
            throw typeMismatch([Key].self, "keyed map")
        }
        var dict: [String: MPValue] = [:]
        for (k, v) in pairs { if case .string(let s) = k { dict[s] = v } }
        return KeyedDecodingContainer(_MPKeyedDecoding<Key>(dict: dict, codingPath: codingPath))
    }
    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        guard case .array(let items) = value else {
            throw typeMismatch([Any].self, "unkeyed array")
        }
        return _MPUnkeyedDecoding(items: items, codingPath: codingPath)
    }
    func singleValueContainer() throws -> SingleValueDecodingContainer {
        _MPSingleValueDecoding(value: value, codingPath: codingPath)
    }

    private func typeMismatch(_ t: Any.Type, _ expected: String) -> DecodingError {
        DecodingError.typeMismatch(t, .init(codingPath: codingPath,
            debugDescription: "expected \(expected)"))
    }
}

// Shared scalar extraction so all decode containers agree on coercions.
enum MPScalar {
    static func int<T: FixedWidthInteger>(_ v: MPValue, _ path: [CodingKey]) throws -> T {
        switch v {
        case .int(let i):
            guard let r = T(exactly: i) else { throw overflow(T.self, path) }
            return r
        case .uint(let u):
            guard let r = T(exactly: u) else { throw overflow(T.self, path) }
            return r
        case .double(let d):
            guard let r = T(exactly: d) else { throw overflow(T.self, path) }
            return r
        default: throw mismatch(T.self, "integer", path)
        }
    }
    static func double(_ v: MPValue, _ path: [CodingKey]) throws -> Double {
        switch v {
        case .double(let d): return d
        case .int(let i): return Double(i)
        case .uint(let u): return Double(u)
        default: throw mismatch(Double.self, "double", path)
        }
    }
    static func bool(_ v: MPValue, _ path: [CodingKey]) throws -> Bool {
        guard case .bool(let b) = v else { throw mismatch(Bool.self, "bool", path) }
        return b
    }
    static func string(_ v: MPValue, _ path: [CodingKey]) throws -> String {
        guard case .string(let s) = v else { throw mismatch(String.self, "string", path) }
        return s
    }
    static func mismatch(_ t: Any.Type, _ e: String, _ p: [CodingKey]) -> DecodingError {
        DecodingError.typeMismatch(t, .init(codingPath: p, debugDescription: "expected \(e)"))
    }
    static func overflow(_ t: Any.Type, _ p: [CodingKey]) -> DecodingError {
        DecodingError.dataCorrupted(.init(codingPath: p,
            debugDescription: "value does not fit in \(t)"))
    }
}

private func decodeNested<T: Decodable>(
    _ type: T.Type, from value: MPValue, codingPath: [CodingKey]
) throws -> T {
    if type == Data.self {
        guard case .binary(let b) = value else {
            throw MPScalar.mismatch(Data.self, "binary", codingPath)
        }
        return Data(b) as! T
    }
    if type == Date.self {
        let secs = try MPScalar.double(value, codingPath)
        return Date(timeIntervalSince1970: secs) as! T
    }
    var dec = _MPDecoder(value: value); dec.codingPath = codingPath
    return try T(from: dec)
}

private struct _MPKeyedDecoding<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let dict: [String: MPValue]
    var codingPath: [CodingKey]
    var allKeys: [Key] { dict.keys.compactMap { Key(stringValue: $0) } }

    func contains(_ key: Key) -> Bool { dict[key.stringValue] != nil }

    private func value(_ key: Key) throws -> MPValue {
        guard let v = dict[key.stringValue] else {
            throw DecodingError.keyNotFound(key, .init(codingPath: codingPath,
                debugDescription: "no value for key \(key.stringValue)"))
        }
        return v
    }
    func decodeNil(forKey key: Key) throws -> Bool {
        guard let v = dict[key.stringValue] else { return true }
        if case .nil = v { return true }
        return false
    }
    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { try MPScalar.bool(value(key), codingPath) }
    func decode(_ type: String.Type, forKey key: Key) throws -> String { try MPScalar.string(value(key), codingPath) }
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double { try MPScalar.double(value(key), codingPath) }
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float { Float(try MPScalar.double(value(key), codingPath)) }
    func decode(_ type: Int.Type, forKey key: Key) throws -> Int { try MPScalar.int(value(key), codingPath) }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try MPScalar.int(value(key), codingPath) }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try MPScalar.int(value(key), codingPath) }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try MPScalar.int(value(key), codingPath) }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try MPScalar.int(value(key), codingPath) }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try MPScalar.int(value(key), codingPath) }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try MPScalar.int(value(key), codingPath) }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try MPScalar.int(value(key), codingPath) }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try MPScalar.int(value(key), codingPath) }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try MPScalar.int(value(key), codingPath) }
    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        try decodeNested(type, from: try value(key), codingPath: codingPath + [key])
    }
    func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type, forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey> {
        var dec = _MPDecoder(value: try value(key)); dec.codingPath = codingPath + [key]
        return try dec.container(keyedBy: type)
    }
    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        var dec = _MPDecoder(value: try value(key)); dec.codingPath = codingPath + [key]
        return try dec.unkeyedContainer()
    }
    func superDecoder() throws -> Decoder { _MPDecoder(value: .map([])) }
    func superDecoder(forKey key: Key) throws -> Decoder {
        var dec = _MPDecoder(value: try value(key)); dec.codingPath = codingPath + [key]; return dec
    }
}

private struct _MPUnkeyedDecoding: UnkeyedDecodingContainer {
    let items: [MPValue]
    var codingPath: [CodingKey]
    var currentIndex = 0
    var count: Int? { items.count }
    var isAtEnd: Bool { currentIndex >= items.count }

    private mutating func next() throws -> MPValue {
        guard !isAtEnd else {
            throw DecodingError.valueNotFound(MPValue.self, .init(codingPath: codingPath,
                debugDescription: "unkeyed container is at end"))
        }
        defer { currentIndex += 1 }
        return items[currentIndex]
    }
    mutating func decodeNil() throws -> Bool {
        if isAtEnd { return false }
        if case .nil = items[currentIndex] { currentIndex += 1; return true }
        return false
    }
    mutating func decode(_ type: Bool.Type) throws -> Bool { try MPScalar.bool(next(), codingPath) }
    mutating func decode(_ type: String.Type) throws -> String { try MPScalar.string(next(), codingPath) }
    mutating func decode(_ type: Double.Type) throws -> Double { try MPScalar.double(next(), codingPath) }
    mutating func decode(_ type: Float.Type) throws -> Float { Float(try MPScalar.double(next(), codingPath)) }
    mutating func decode(_ type: Int.Type) throws -> Int { try MPScalar.int(next(), codingPath) }
    mutating func decode(_ type: Int8.Type) throws -> Int8 { try MPScalar.int(next(), codingPath) }
    mutating func decode(_ type: Int16.Type) throws -> Int16 { try MPScalar.int(next(), codingPath) }
    mutating func decode(_ type: Int32.Type) throws -> Int32 { try MPScalar.int(next(), codingPath) }
    mutating func decode(_ type: Int64.Type) throws -> Int64 { try MPScalar.int(next(), codingPath) }
    mutating func decode(_ type: UInt.Type) throws -> UInt { try MPScalar.int(next(), codingPath) }
    mutating func decode(_ type: UInt8.Type) throws -> UInt8 { try MPScalar.int(next(), codingPath) }
    mutating func decode(_ type: UInt16.Type) throws -> UInt16 { try MPScalar.int(next(), codingPath) }
    mutating func decode(_ type: UInt32.Type) throws -> UInt32 { try MPScalar.int(next(), codingPath) }
    mutating func decode(_ type: UInt64.Type) throws -> UInt64 { try MPScalar.int(next(), codingPath) }
    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try decodeNested(type, from: next(), codingPath: codingPath)
    }
    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type
    ) throws -> KeyedDecodingContainer<NestedKey> {
        var dec = _MPDecoder(value: try next()); dec.codingPath = codingPath
        return try dec.container(keyedBy: type)
    }
    mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
        var dec = _MPDecoder(value: try next()); dec.codingPath = codingPath
        return try dec.unkeyedContainer()
    }
    mutating func superDecoder() throws -> Decoder {
        var dec = _MPDecoder(value: try next()); dec.codingPath = codingPath; return dec
    }
}

private struct _MPSingleValueDecoding: SingleValueDecodingContainer {
    let value: MPValue
    var codingPath: [CodingKey]

    func decodeNil() -> Bool { if case .nil = value { return true }; return false }
    func decode(_ type: Bool.Type) throws -> Bool { try MPScalar.bool(value, codingPath) }
    func decode(_ type: String.Type) throws -> String { try MPScalar.string(value, codingPath) }
    func decode(_ type: Double.Type) throws -> Double { try MPScalar.double(value, codingPath) }
    func decode(_ type: Float.Type) throws -> Float { Float(try MPScalar.double(value, codingPath)) }
    func decode(_ type: Int.Type) throws -> Int { try MPScalar.int(value, codingPath) }
    func decode(_ type: Int8.Type) throws -> Int8 { try MPScalar.int(value, codingPath) }
    func decode(_ type: Int16.Type) throws -> Int16 { try MPScalar.int(value, codingPath) }
    func decode(_ type: Int32.Type) throws -> Int32 { try MPScalar.int(value, codingPath) }
    func decode(_ type: Int64.Type) throws -> Int64 { try MPScalar.int(value, codingPath) }
    func decode(_ type: UInt.Type) throws -> UInt { try MPScalar.int(value, codingPath) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try MPScalar.int(value, codingPath) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try MPScalar.int(value, codingPath) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try MPScalar.int(value, codingPath) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try MPScalar.int(value, codingPath) }
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try decodeNested(type, from: value, codingPath: codingPath)
    }
}
