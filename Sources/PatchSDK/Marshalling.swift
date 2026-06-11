import Foundation
import WasmKit

// Marshalling — moves Swift values across the host <-> WASM boundary per the
// Patch v0 ABI. Implements the plan's type table (patch-plan.md ~lines 698–706):
//
//   | Swift type        | WASM representation                                  |
//   |-------------------|-----------------------------------------------------|
//   | Bool / Int32      | i32                                                 |
//   | Int / Int64       | i64                                                 |
//   | Double            | f64                                                 |
//   | String / Data     | (ptr: i32, len: i32) into linear memory             |
//   | Optional<T>       | (tag: i32, value...) — tag 0 = nil, 1 = present     |
//   | any Codable       | (ptr: i32, len: i32) of a MessagePack blob          |
//
// A marshalled value lowers to one or more `Value`s (the WASM ABI types). Values
// that live in linear memory (String/Data/Codable) require a guest allocator;
// `MarshalContext` carries the `WASMRuntime` so lowering can allocate and
// raising can read back. Allocated buffers are tracked and freed when the
// context is finalized (one context per host->wasm call).

/// Carries the runtime + bookkeeping for one host->wasm call's marshalling.
public final class MarshalContext {
    public let runtime: WASMRuntime
    /// Guest pointers allocated during lowering, freed by `release()`.
    private var allocated: [UInt32] = []

    public init(runtime: WASMRuntime) { self.runtime = runtime }

    /// Allocate a guest buffer, copy `bytes`, and record it for cleanup.
    public func writeOwnedBuffer(_ bytes: [UInt8]) throws -> (ptr: UInt32, len: UInt32) {
        let (ptr, len) = try runtime.writeBuffer(bytes)
        if ptr != 0 { allocated.append(ptr) }
        return (ptr, len)
    }

    /// Free all buffers allocated during this call. Call once, after the call.
    public func release() {
        for p in allocated { runtime.free(p) }
        allocated.removeAll()
    }
}

/// A Swift type that can cross the host <-> WASM boundary.
///
/// `lower` turns a Swift value into the WASM `Value`s passed as call arguments
/// (allocating into guest memory via `ctx` when needed). `raise` reconstructs a
/// Swift value from the WASM `Value`s a call returned, consuming them from the
/// front of `values`.
public protocol WASMBridgeable {
    /// Lower `self` to its WASM argument values.
    func lower(into ctx: MarshalContext) throws -> [Value]
    /// Raise a value from the front of `values`, advancing `index`.
    static func raise(from values: [Value], index: inout Int, ctx: MarshalContext) throws -> Self
}

// MARK: - Errors

public enum MarshalError: Error, CustomStringConvertible {
    case notEnoughValues(expected: String)
    case wrongValueKind(expected: String, at: Int)

    public var description: String {
        switch self {
        case .notEnoughValues(let e): return "marshalling: ran out of WASM values, expected \(e)"
        case .wrongValueKind(let e, let i): return "marshalling: expected \(e) at value index \(i)"
        }
    }
}

// MARK: - Value-reading helpers

private func takeI32(_ values: [Value], _ index: inout Int) throws -> UInt32 {
    guard index < values.count else { throw MarshalError.notEnoughValues(expected: "i32") }
    let v = values[index]; index += 1
    guard case .i32(let raw) = v else { throw MarshalError.wrongValueKind(expected: "i32", at: index - 1) }
    return raw
}
private func takeI64(_ values: [Value], _ index: inout Int) throws -> UInt64 {
    guard index < values.count else { throw MarshalError.notEnoughValues(expected: "i64") }
    let v = values[index]; index += 1
    guard case .i64(let raw) = v else { throw MarshalError.wrongValueKind(expected: "i64", at: index - 1) }
    return raw
}
private func takeF64(_ values: [Value], _ index: inout Int) throws -> Double {
    guard index < values.count else { throw MarshalError.notEnoughValues(expected: "f64") }
    let v = values[index]; index += 1
    guard case .f64(let bits) = v else { throw MarshalError.wrongValueKind(expected: "f64", at: index - 1) }
    return Double(bitPattern: bits)
}

// MARK: - Scalars

extension Bool: WASMBridgeable {
    public func lower(into ctx: MarshalContext) throws -> [Value] { [.i32(self ? 1 : 0)] }
    public static func raise(from values: [Value], index: inout Int, ctx: MarshalContext) throws -> Bool {
        try takeI32(values, &index) != 0
    }
}

extension Int32: WASMBridgeable {
    public func lower(into ctx: MarshalContext) throws -> [Value] { [.i32(UInt32(bitPattern: self))] }
    public static func raise(from values: [Value], index: inout Int, ctx: MarshalContext) throws -> Int32 {
        Int32(bitPattern: try takeI32(values, &index))
    }
}

extension Int64: WASMBridgeable {
    public func lower(into ctx: MarshalContext) throws -> [Value] { [.i64(UInt64(bitPattern: self))] }
    public static func raise(from values: [Value], index: inout Int, ctx: MarshalContext) throws -> Int64 {
        Int64(bitPattern: try takeI64(values, &index))
    }
}

// `Int` is 64-bit on all Apple targets; marshal as i64.
extension Int: WASMBridgeable {
    public func lower(into ctx: MarshalContext) throws -> [Value] { [.i64(UInt64(bitPattern: Int64(self)))] }
    public static func raise(from values: [Value], index: inout Int, ctx: MarshalContext) throws -> Int {
        Int(Int64(bitPattern: try takeI64(values, &index)))
    }
}

extension Double: WASMBridgeable {
    public func lower(into ctx: MarshalContext) throws -> [Value] { [.f64(self.bitPattern)] }
    public static func raise(from values: [Value], index: inout Int, ctx: MarshalContext) throws -> Double {
        try takeF64(values, &index)
    }
}

// MARK: - String / Data — (ptr, len) into linear memory

extension String: WASMBridgeable {
    public func lower(into ctx: MarshalContext) throws -> [Value] {
        let (ptr, len) = try ctx.writeOwnedBuffer([UInt8](self.utf8))
        return [.i32(ptr), .i32(len)]
    }
    public static func raise(from values: [Value], index: inout Int, ctx: MarshalContext) throws -> String {
        let ptr = try takeI32(values, &index)
        let len = try takeI32(values, &index)
        let bytes = try ctx.runtime.read(ptr: ptr, len: len)
        return String(decoding: bytes, as: UTF8.self)
    }
}

extension Data: WASMBridgeable {
    public func lower(into ctx: MarshalContext) throws -> [Value] {
        let (ptr, len) = try ctx.writeOwnedBuffer([UInt8](self))
        return [.i32(ptr), .i32(len)]
    }
    public static func raise(from values: [Value], index: inout Int, ctx: MarshalContext) throws -> Data {
        let ptr = try takeI32(values, &index)
        let len = try takeI32(values, &index)
        return Data(try ctx.runtime.read(ptr: ptr, len: len))
    }
}

// MARK: - Optional — (tag: i32, value...)
//
// tag 0 = nil (no following value words), tag 1 = present (Wrapped's words
// follow). Lowering nil emits ONLY the tag; the guest must know Wrapped's arity
// to skip the right number of words when present. This matches the plan's
// "(tag, value)" representation.

/// Alias for `[WasmKit.Value]` — the WASM word list a marshalled value lowers to.
///
/// This alias exists SOLELY to spell the array type in the `Optional:
/// WASMBridgeable` conditional-conformance witnesses below. It works around a
/// Swift 6 whole-module type-checker bug: when ANY UIKit-family framework (UIKit,
/// StoreKit, MediaPlayer, PhotosUI, MessageUI — all imported by the device
/// bridges) is in the module, it transitively re-exports SwiftUI, which adds a
/// pile of conditional `extension Optional: <SwiftUI protocol> where Wrapped:
/// <that protocol>` conformances. With those in scope, type-checking a witness in
/// OUR `extension Optional: WASMBridgeable` that spells a method type as a SUGARED
/// array of a non-stdlib type *literally* (`[WasmKit.Value]`) trips a spurious
/// global conformance lookup and mis-diagnoses `type 'Wrapped' does not conform to
/// protocol 'Gesture'`. Spelling every `[Value]` in these witnesses through this
/// typealias defeats the bad lookup; the conformance, ABI, and runtime behavior
/// are byte-for-byte unchanged. (The other conformances above — Bool/Int/String/…
/// — are NOT on `Optional`, so they never hit the bug and need no alias.)
public typealias MarshalWords = [Value]

extension Optional: WASMBridgeable where Wrapped: WASMBridgeable {
    public func lower(into ctx: MarshalContext) throws -> MarshalWords {
        switch self {
        case .none: return [.i32(0)]
        case .some(let w): return [.i32(1)] + (try w.lower(into: ctx))
        }
    }
    public static func raise(from values: MarshalWords, index: inout Int, ctx: MarshalContext) throws -> Optional<Wrapped> {
        let tag = try takeI32(values, &index)
        if tag == 0 { return .none }
        return .some(try Wrapped.raise(from: values, index: &index, ctx: ctx))
    }
}

// MARK: - Codable via MessagePack — (ptr, len) of a MessagePack blob
//
// `WASMBridgeable` and `Codable` overlap (String/Data/Int are both), so we do
// NOT make `Codable` conform automatically. Instead, wrap a Codable value in
// `MessagePackBridge` to marshal it as a MessagePack (ptr,len) blob. Generated
// bridge code (Day 3+) emits this wrapper for user structs/enums.

public struct MessagePackBridge<T: Codable>: WASMBridgeable {
    public var value: T
    public init(_ value: T) { self.value = value }

    public func lower(into ctx: MarshalContext) throws -> [Value] {
        let bytes = try MessagePack.encode(value)
        let (ptr, len) = try ctx.writeOwnedBuffer(bytes)
        return [.i32(ptr), .i32(len)]
    }
    public static func raise(from values: [Value], index: inout Int, ctx: MarshalContext) throws -> MessagePackBridge<T> {
        let ptr = try takeI32(values, &index)
        let len = try takeI32(values, &index)
        let bytes = try ctx.runtime.read(ptr: ptr, len: len)
        return MessagePackBridge(try MessagePack.decode(T.self, from: bytes))
    }
}

// MARK: - Convenience: marshal a Codable directly to/from MessagePack bytes
//
// Used by tests and by the host side of a call when the (ptr,len) is produced
// by the guest's own allocator/`store_result` convention.

public extension MessagePack {
    /// Encode a Codable value and write it into guest memory via the runtime's
    /// allocator, returning the guest `(ptr, len)`.
    static func writeBlob<T: Encodable>(_ value: T, into runtime: WASMRuntime) throws -> (ptr: UInt32, len: UInt32) {
        try runtime.writeBuffer(try encode(value))
    }
    /// Read a MessagePack blob back from guest memory and decode it.
    static func readBlob<T: Decodable>(_ type: T.Type, ptr: UInt32, len: UInt32, from runtime: WASMRuntime) throws -> T {
        try decode(type, from: runtime.read(ptr: ptr, len: len))
    }
}
