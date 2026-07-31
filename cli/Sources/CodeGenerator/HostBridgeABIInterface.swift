// SPDX-License-Identifier: Apache-2.0

import Foundation

// ===========================================================================
// THE ABI-CORE SEAM (Lever #2, part B).
//
// The TLV value format, the symbol-id derivation, the arg-blob / result-decoder
// codegen, the `HostBridgeSymbol` manifest model, and the three flat imports
// (`patch_host.call` / `.release` / `.have`) are owned by a PARALLEL agent in
// `HostBridgeABI.swift`. `GeneralBridgeRewriter` (the classifier + guest-sequence
// emitter) codes against the small `HostBridgeABIProvider` protocol below so it
// compiles + tests standalone, and the real ABI core is a drop-in.
//
// AT INTEGRATION (what the parallel agent reconnects):
//   1. Delete `StubHostBridgeABI` below (or keep it for tests only).
//   2. Make the real ABI core's primary type conform to `HostBridgeABIProvider`,
//      OR add a thin adapter. The protocol is the EXACT surface this component
//      needs — nothing more.
//   3. Replace `HostBridgeValueTag` here with the ABI core's canonical `TLVTag`
//      enum IF the parallel agent named it differently — they MUST be the same
//      wire tags (the prototype's: nil=0, i64=1, f64=2, bool=3, string=4,
//      bytes=5, handle=6, error=7; see experiments/host-bridge-generalized/
//      guest/Sources/Guest/main.swift `ValueTag`). To avoid a competing
//      definition, this file declares `HostBridgeValueTag` as the SINGLE shared
//      tag enum the rewriter uses; the ABI core should ADOPT it (or typealias
//      its `TLVTag` to it) rather than introduce a second one. Either way, the
//      raw values above are load-bearing and fixed by the proven prototype.
//
// IMPORTANT — this file deliberately does NOT define:
//   - a symbol-id HASH (only `symbolIdLiteral(...)` — the stub returns a
//     legible truncation; the real core returns `truncate32(SHA256(sig))`);
//   - the TLV byte layout / ArgWriter struct (the stub emits a plausible-shaped
//     `_PatchBridgeArgWriter` so tests can assert the sequence; the real core
//     emits the proven embedded-safe writer);
//   - the `HostBridgeSymbol` manifest record / the three import declarations.
// Those are the parallel agent's. This file owns ONLY the codegen seam the
// rewriter calls.
// ===========================================================================

/// The single shared TLV value tag enum (matches the proven prototype's
/// `ValueTag`, raw values fixed). The ABI core SHOULD adopt this (or typealias)
/// rather than declare a competing `TLVTag`.
public enum HostBridgeValueTag: UInt8, Sendable, Equatable, CaseIterable {
    case nilValue = 0   // no payload (also Void)
    case i64      = 1   // 8 bytes LE
    case f64      = 2   // 8 bytes LE bitpattern (finite-clamped)
    case bool     = 3   // 1 byte 0/1
    case string   = 4   // [len:u32 LE][utf8]
    case bytes    = 5   // [len:u32 LE][raw] (flat-Codable sub-blob)
    case handle   = 6   // 4 bytes LE Int32 (opaque native-object proxy)
    case error    = 7   // [len:u32 LE][utf8 message] — host failure → demote
}

/// What `GeneralBridgeRewriter` needs from the ABI core, and NOTHING more. The
/// real core (parallel agent) conforms its primary type to this; the stub below
/// lets the rewriter build + test standalone.
///
/// Each method is pure codegen (a String of guest Swift) or a stable id literal.
/// None of them touch a WASM toolchain — they EMIT the source the real-source
/// compile will build.
public protocol HostBridgeABIProvider: Sendable {

    // ---- symbol id ----

    /// The Swift literal for the stable symbol id of a canonical signature.
    /// Real core: `truncate32(SHA256(canonicalSignature))` (an `Int32` literal).
    /// Stub: a legible deterministic value so tests can assert the wiring.
    func symbolIdLiteral(forCanonicalSignature signature: String) -> String

    // ---- guest-side import call codegen ----

    /// The expression that constructs a fresh arg-blob writer (`var __pb = …`).
    /// Real core: the embedded-safe `_PatchBridgeArgWriter()`.
    func makeArgWriterExpression() -> String

    /// One statement that appends an arg of `tag` carrying `expr` to `writerVar`.
    /// e.g. `__pb.f64(subtotal)` / `__pb.handle(__h0)`.
    func argEncodeStatement(writerVar: String, tag: HostBridgeValueTag, expr: String) -> String

    /// The expression that calls the generic dispatch import with the finished
    /// blob and decodes the single result record into the ABI core's `Decoded`
    /// enum. e.g. `_patchBridgeCall(<id>, __pb)`.
    func callImportExpression(symbolIdLiteral: String, writerVar: String) -> String

    /// The expression that pre-flights a symbol id via the `have` import.
    /// e.g. `_patchBridgeHave(<id>)` (returns `Int32`, 1 present / 0 absent).
    func haveImportCall(symbolIdLiteral: String) -> String

    // ---- result decoding ----

    /// The `case` pattern that binds a SUCCESSFUL decode of `tag`.
    /// e.g. `.f64(let __v)` / `.string(let __v)` / `.nilValue`.
    func resultDecodeSuccessPattern(for tag: HostBridgeValueTag) -> String

    /// The expression yielding the bound success value for `tag` (matching the
    /// pattern above). e.g. `__v` for a scalar, `()` for `.nilValue`, a
    /// handle-proxy wrap for `.handle`.
    func resultSuccessExpression(for tag: HostBridgeValueTag) -> String

    /// The Swift return type a `tag` result decodes to (for the emitted closure's
    /// `-> <RetType>`). e.g. `Double`, `String`, `Void`, the handle-proxy type.
    func swiftReturnType(for tag: HostBridgeValueTag, isHandle: Bool) -> String
}

// ===========================================================================
// MARK: - StubHostBridgeABI — minimal standalone implementation
//
// A self-contained stub so `GeneralBridgeRewriter` compiles + its tests run
// without the parallel ABI core. The emitted shapes are PLAUSIBLE (close to
// what the real core will emit) so the sequence tests assert real structure,
// but the byte-format / hash details are intentionally placeholders the real
// core replaces. DELETE (or keep test-only) at integration.
// ===========================================================================
public struct StubHostBridgeABI: HostBridgeABIProvider {
    public init() {}

    public func symbolIdLiteral(forCanonicalSignature signature: String) -> String {
        // A deterministic, legible 32-bit fold (NOT the real SHA256 truncation —
        // the real core supplies that). Stable across runs so tests can pin it.
        var h: UInt32 = 2166136261
        for b in signature.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return "Int32(bitPattern: 0x\(String(h, radix: 16)))"
    }

    public func makeArgWriterExpression() -> String { "_PatchBridgeArgWriter()" }

    public func argEncodeStatement(writerVar: String, tag: HostBridgeValueTag, expr: String) -> String {
        let m: String
        switch tag {
        case .i64:    m = "i64(Int64(\(expr)))"
        case .f64:    m = "f64(Double(\(expr)))"
        case .bool:   m = "bool(\(expr))"
        case .string: m = "string(\(expr))"
        case .bytes:  m = "bytes(\(expr))"
        case .handle: m = "handle(\(expr))"
        case .nilValue, .error:
            // Never an arg tag in practice; emit a no-op-shaped call so a
            // mis-classification still compiles to something inert.
            m = "nilValue()"
        }
        return "\(writerVar).\(m)"
    }

    public func callImportExpression(symbolIdLiteral: String, writerVar: String) -> String {
        "_patchBridgeCall(\(symbolIdLiteral), \(writerVar))"
    }

    public func haveImportCall(symbolIdLiteral: String) -> String {
        "_patchBridgeHave(\(symbolIdLiteral))"
    }

    public func resultDecodeSuccessPattern(for tag: HostBridgeValueTag) -> String {
        switch tag {
        case .nilValue: return ".nilValue"
        case .i64:      return ".i64(let __v)"
        case .f64:      return ".f64(let __v)"
        case .bool:     return ".bool(let __v)"
        case .string:   return ".string(let __v)"
        case .bytes:    return ".bytes(let __v)"
        case .handle:   return ".handle(let __v)"
        case .error:    return ".error(let __v)"
        }
    }

    public func resultSuccessExpression(for tag: HostBridgeValueTag) -> String {
        switch tag {
        case .nilValue: return "()"
        case .error:    return "()"   // shouldn't be a success arm
        case .handle:   return "_PatchBridgeHandle(__v)"
        case .i64, .f64, .bool, .string, .bytes:
            return "__v"
        }
    }

    public func swiftReturnType(for tag: HostBridgeValueTag, isHandle: Bool) -> String {
        if isHandle { return "_PatchBridgeHandle" }
        switch tag {
        case .nilValue: return "Void"
        case .i64:      return "Int"
        case .f64:      return "Double"
        case .bool:     return "Bool"
        case .string:   return "String"
        case .bytes:    return "[UInt8]"
        case .handle:   return "_PatchBridgeHandle"
        case .error:    return "Void"
        }
    }
}
