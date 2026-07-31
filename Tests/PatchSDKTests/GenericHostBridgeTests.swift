// SPDX-License-Identifier: MIT

import XCTest
import Foundation
import WasmKit
import WasmKitWASI
@testable import PatchHostBridge

// ===========================================================================
// Tests for the generalized "call what's already linked" host bridge (Lever #2,
// part A) — the PatchHostBridge target. Ported from the proven prototype
// (experiments/host-bridge-generalized), driving the SAME guest WASM through
// WasmKit (the SDK's actual runtime) and asserting each guest result against the
// host's OWN real native computation.
//
// Three groups:
//   1. Round-trips through EXECUTING WASM: a scalar free fn, the handle-proxy
//      (construct → method → property → multi-call → leak-free release), the
//      demote path (unknown id → have==0 + .error).
//   2. Direct unit tests of the TLV codec (exact byte layout per DESIGN §2.2).
//   3. Direct unit tests of the HandleTable + manifest reader.
// ===========================================================================

// MARK: - "Already-linked native code" the guest will call (mirrors the prototype)

private enum PricingEngine {
    // tier 0 = none, 1 = silver (5%), 2 = gold (12%)
    static func discount(subtotal: Double, tier: Int) -> Double {
        let pct: Double = (tier == 2) ? 0.12 : (tier == 1) ? 0.05 : 0.0
        return (subtotal * (1.0 - pct) * 100).rounded() / 100
    }
}

private func makeCurrencyFormatter(_ code: String) -> NumberFormatter {
    let f = NumberFormatter()
    f.numberStyle = .currency
    f.currencyCode = code
    f.locale = Locale(identifier: "en_US") // deterministic for the test
    return f
}

/// fnv1a mirroring the guest, so the host can verify byte-exact transfer.
private func fnv1a(_ s: String) -> Int32 {
    var h: UInt32 = 2166136261
    for b in s.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
    return Int32(bitPattern: h)
}

// The same small symbol ids the prototype guest uses.
private enum Sym {
    static let computeDiscount: Int32 = 101   // (subtotal: f64, tier: i64) -> f64
    static let makeFormatter: Int32   = 201   // (currencyCode: String) -> handle
    static let formatAmount: Int32    = 202   // (h: handle, amount: f64) -> String
    static let formatterSymbol: Int32 = 203   // (h: handle) -> String (property)
    static let unknown: Int32         = 999   // deliberately unregistered
}

/// Build the production controller with the prototype's registry — exactly the
/// thunks the build-time resolver-thunk would generate, expressed against the
/// public `register(id:signature:_:)` API.
private func makeBridge() -> PatchHostBridge {
    let bridge = PatchHostBridge()

    // 101: scalar free function.
    bridge.register(id: Sym.computeDiscount, signature: "PricingEngine.discount(subtotal:Double,tier:Int)->Double") { args, _ in
        try args.requireArity(2)
        return .f64(PricingEngine.discount(subtotal: try args.f64(0), tier: Int(try args.i64(1))))
    }

    // 201: CONSTRUCT a live native object → return a handle.
    bridge.register(id: Sym.makeFormatter, signature: "makeCurrencyFormatter(String)->NumberFormatter") { args, handles in
        try args.requireArity(1)
        let f = makeCurrencyFormatter(try args.string(0))
        return .handle(handles.retain(f))
    }

    // 202: METHOD call through a handle.
    bridge.register(id: Sym.formatAmount, signature: "NumberFormatter.string(from:NSNumber)->String?") { args, handles in
        try args.requireArity(2)
        guard let f = handles.resolve(try args.handle(0), as: NumberFormatter.self) else {
            return .error("stale/invalid formatter handle")
        }
        return .string(f.string(from: NSNumber(value: try args.f64(1))) ?? "")
    }

    // 203: PROPERTY read through a handle.
    bridge.register(id: Sym.formatterSymbol, signature: "NumberFormatter.currencySymbol->String") { args, handles in
        guard let f = handles.resolve(try args.handle(0), as: NumberFormatter.self) else {
            return .error("stale/invalid formatter handle")
        }
        return .string(f.currencySymbol ?? "")
    }

    return bridge
}

final class GenericHostBridgeTests: XCTestCase {

    // MARK: - WASM round-trip harness

    private func fixtureBytes() throws -> [UInt8] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "GenericHostBridgeGuest", withExtension: "wasm"))
        return [UInt8](try Data(contentsOf: url))
    }

    /// Instantiate the guest with WASI + the three generic imports wired to a
    /// freshly-built controller. Returns the WasmKit instance and the controller
    /// (the test asserts the controller's handle table is leak-free afterwards).
    private func makeInstance(_ bridge: PatchHostBridge) throws -> (Instance, WASIBridgeToHost) {
        let engine = Engine()
        let store = Store(engine: engine)
        let wasi = try WASIBridgeToHost()
        var imports = Imports()
        wasi.link(to: &imports, store: store)
        GenericHostBridge(bridge: bridge).register(into: &imports, store: store)

        let module = try parseWasm(bytes: try fixtureBytes())
        let instance = try module.instantiate(store: store, imports: imports)
        try wasi.initialize(instance)
        return (instance, wasi)
    }

    private func callI64(_ inst: Instance, _ name: String) throws -> Int64 {
        let fn = try XCTUnwrap(inst.exports[function: name], "missing export \(name)")
        let r = try fn.invoke([])
        return r.isEmpty ? 0 : Int64(bitPattern: r[0].i64)
    }
    private func callI32(_ inst: Instance, _ name: String) throws -> Int32 {
        let fn = try XCTUnwrap(inst.exports[function: name], "missing export \(name)")
        let r = try fn.invoke([])
        return r.isEmpty ? 0 : Int32(bitPattern: r[0].i32)
    }
    private func resetArena(_ inst: Instance) {
        _ = try? inst.exports[function: "patch_reset_arena"]?.invoke([])
    }

    // MARK: - (a) scalar free function

    func testScalarFreeCallRoundTrip() throws {
        let bridge = makeBridge()
        let (inst, _) = try makeInstance(bridge)
        // host computes the SAME real native value to assert against.
        let expected = Int64((PricingEngine.discount(subtotal: 129.99, tier: 2) * 100).rounded())
        XCTAssertEqual(try callI64(inst, "test_scalar_free_call"), expected,
                       "guest called native PricingEngine.discount(129.99, gold) through the generic bridge")
        XCTAssertEqual(expected, 11439, "the prototype's documented exact cents result")
    }

    // MARK: - (b) handle proxy — construct / method / property / multi-call / leak-free

    func testHandleProxyMethodRoundTrip() throws {
        let bridge = makeBridge()
        let (inst, _) = try makeInstance(bridge)
        resetArena(inst)
        let efmt = makeCurrencyFormatter("EUR")
        let expected = fnv1a(efmt.string(from: NSNumber(value: 1234.5)) ?? "")
        XCTAssertEqual(try callI32(inst, "test_handle_proxy_format_checksum"), expected,
                       "guest formatted 1234.5 via the host-held NumberFormatter(EUR) by handle")
        // The guest released its handle inside the export → no leak.
        XCTAssertEqual(bridge.handles.liveCount, 0, "handle released after the method round-trip")
    }

    func testHandleProxyPropertyRoundTrip() throws {
        let bridge = makeBridge()
        let (inst, _) = try makeInstance(bridge)
        resetArena(inst)
        let jfmt = makeCurrencyFormatter("JPY")
        let expected = fnv1a(jfmt.currencySymbol ?? "")
        XCTAssertEqual(try callI32(inst, "test_handle_proxy_symbol_checksum"), expected,
                       "guest read .currencySymbol (JPY) via the handle")
        XCTAssertEqual(bridge.handles.liveCount, 0, "handle released after the property read")
    }

    func testHandleMultiCallOneLiveObject() throws {
        let bridge = makeBridge()
        let (inst, _) = try makeInstance(bridge)
        resetArena(inst)
        let ufmt = makeCurrencyFormatter("USD")
        let expected = Int32([9.99, 100.0, 0.5].reduce(0) {
            $0 + (ufmt.string(from: NSNumber(value: $1))?.utf8.count ?? 0)
        })
        XCTAssertEqual(try callI32(inst, "test_handle_multi_call_len"), expected,
                       "ONE live native formatter, 3 amounts formatted through it across 3 guest calls")
        XCTAssertEqual(bridge.handles.liveCount, 0, "the single handle released after the multi-call")
    }

    func testLeakFreeAcrossAllHandleTests() throws {
        // Run every handle-using export in sequence against ONE controller; the
        // table must be empty at the end (every test releases its handle).
        let bridge = makeBridge()
        let (inst, _) = try makeInstance(bridge)
        resetArena(inst); _ = try callI32(inst, "test_handle_proxy_format_checksum")
        resetArena(inst); _ = try callI32(inst, "test_handle_proxy_symbol_checksum")
        resetArena(inst); _ = try callI32(inst, "test_handle_multi_call_len")
        XCTAssertEqual(bridge.handles.liveCount, 0,
                       "host handle table empty after balanced construct/release (no leaked native objects)")
    }

    // MARK: - (c) demote / error path + have() pre-flight

    func testHavePreflight() throws {
        let bridge = makeBridge()
        let (inst, _) = try makeInstance(bridge)
        XCTAssertEqual(try callI32(inst, "test_known_symbol_present"), 1,
                       "have(known) == 1")
    }

    func testUnknownSymbolDemotes() throws {
        let bridge = makeBridge()
        let (inst, _) = try makeInstance(bridge)
        // The guest export asserts BOTH have(999)==0 AND call(999) → tagged .error,
        // returning 1 only if both held.
        XCTAssertEqual(try callI32(inst, "test_unknown_symbol_errors"), 1,
                       "unknown symbolId: have()==0 AND call() returns a tagged .error (the demote path)")
    }

    // MARK: - Controller-level dispatch (no WASM) — direct demote-safety checks

    func testControllerUnknownIdIsTaggedError() {
        let bridge = makeBridge()
        XCTAssertFalse(bridge.have(Sym.unknown))
        if case .error = bridge.call(Sym.unknown, argsBlob: TLVCodec.encodeArgs([.i64(1)])) {
            // expected
        } else {
            XCTFail("an unregistered id must return a tagged .error")
        }
    }

    func testControllerThunkThrowBecomesError() {
        let bridge = PatchHostBridge()
        bridge.register(id: 7) { args, _ in
            // arity mismatch → throws → must surface as .error, not a crash.
            try args.requireArity(2)
            return .nilValue
        }
        if case .error = bridge.call(7, argsBlob: TLVCodec.encodeArgs([.i64(1)])) {
            // expected
        } else {
            XCTFail("a throwing thunk must demote to a tagged .error")
        }
    }

    func testControllerMalformedArgBlobIsError() {
        let bridge = makeBridge()
        // A truncated arg blob (claims 1 arg, no record bytes) must demote, never crash.
        let malformed: [UInt8] = [0x01]
        if case .error = bridge.call(Sym.computeDiscount, argsBlob: malformed) {
            // expected
        } else {
            XCTFail("a malformed arg blob must return a tagged .error")
        }
    }

    func testStaleHandleResolvesToError() {
        let bridge = makeBridge()
        // A handle that was never issued resolves to nil → the thunk's guard
        // returns a tagged .error (never a wrong object).
        let args = TLVCodec.encodeArgs([.handle(424242), .f64(1.0)])
        if case .error = bridge.call(Sym.formatAmount, argsBlob: args) {
            // expected
        } else {
            XCTFail("a stale handle must resolve to a tagged .error")
        }
    }

    func testTeardownReleasesHandles() {
        let bridge = makeBridge()
        // Construct two handles via the registered makeFormatter thunk.
        _ = bridge.call(Sym.makeFormatter, argsBlob: TLVCodec.encodeArgs([.string("EUR")]))
        _ = bridge.call(Sym.makeFormatter, argsBlob: TLVCodec.encodeArgs([.string("USD")]))
        XCTAssertEqual(bridge.handles.liveCount, 2)
        bridge.teardown()
        XCTAssertEqual(bridge.handles.liveCount, 0, "teardown drops the whole handle table")
        XCTAssertTrue(bridge.registeredIDs.isEmpty, "teardown drops the registry")
        XCTAssertFalse(bridge.have(Sym.computeDiscount), "have() is false after teardown")
    }
}

// MARK: - TLV codec: exact byte layout (DESIGN §2.2)

final class TLVCodecTests: XCTestCase {

    func testNilEncodesToEmptyBlob() throws {
        XCTAssertEqual(TLVCodec.encodeValue(.nilValue), [],
                       "nil encodes to an EMPTY result blob (the packed-0 void/nil)")
        XCTAssertEqual(try TLVCodec.decodeResult([]), .nilValue)
    }

    func testI64ByteLayout() throws {
        // tag 1, then 8 LE bytes. 0x0102030405060708 → bytes 08 07 06 05 04 03 02 01.
        let v: Int64 = 0x0102030405060708
        let blob = TLVCodec.encodeValue(.i64(v))
        XCTAssertEqual(blob, [1, 0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01])
        XCTAssertEqual(try TLVCodec.decodeResult(blob), .i64(v))
    }

    func testNegativeI64TwosComplement() throws {
        let blob = TLVCodec.encodeValue(.i64(-1))
        XCTAssertEqual(blob, [1, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff])
        XCTAssertEqual(try TLVCodec.decodeResult(blob), .i64(-1))
    }

    func testF64ByteLayoutAndRoundTrip() throws {
        let v = 1234.5
        let blob = TLVCodec.encodeValue(.f64(v))
        XCTAssertEqual(blob[0], 2, "tag 2 = f64")
        XCTAssertEqual(blob.count, 9, "tag + 8-byte bitpattern")
        // Reconstruct the bitpattern LE and compare.
        var bits: UInt64 = 0
        for k in 0..<8 { bits |= UInt64(blob[1 + k]) << (UInt64(k) * 8) }
        XCTAssertEqual(Double(bitPattern: bits), v)
        XCTAssertEqual(try TLVCodec.decodeResult(blob), .f64(v))
    }

    func testF64FiniteClampInvariant() throws {
        // Non-finite floats clamp to 0.0 before the bitpattern is taken.
        for bad in [Double.nan, .infinity, -.infinity] {
            let blob = TLVCodec.encodeValue(.f64(bad))
            XCTAssertEqual(try TLVCodec.decodeResult(blob), .f64(0.0),
                           "non-finite \(bad) clamps to 0.0 (the SDK float invariant)")
        }
    }

    func testBoolByteLayout() throws {
        XCTAssertEqual(TLVCodec.encodeValue(.bool(true)), [3, 1])
        XCTAssertEqual(TLVCodec.encodeValue(.bool(false)), [3, 0])
        XCTAssertEqual(try TLVCodec.decodeResult([3, 1]), .bool(true))
        XCTAssertEqual(try TLVCodec.decodeResult([3, 0]), .bool(false))
    }

    func testStringByteLayout() throws {
        // tag 4, [len:u32 LE], utf8. "AB" → 4, 02 00 00 00, 'A', 'B'.
        let blob = TLVCodec.encodeValue(.string("AB"))
        XCTAssertEqual(blob, [4, 0x02, 0x00, 0x00, 0x00, 0x41, 0x42])
        XCTAssertEqual(try TLVCodec.decodeResult(blob), .string("AB"))
    }

    func testStringUTF8MultiByte() throws {
        let s = "€¥"   // € = 3 bytes (U+20AC), ¥ = 2 bytes (U+00A5) → 5 utf8 bytes
        let blob = TLVCodec.encodeValue(.string(s))
        XCTAssertEqual(blob[0], 4)
        XCTAssertEqual(blob[1], UInt8(Array(s.utf8).count), "u32 LE low byte = utf8 byte count")
        XCTAssertEqual(try TLVCodec.decodeResult(blob), .string(s))
    }

    func testBytesByteLayout() throws {
        let b: [UInt8] = [0xde, 0xad, 0xbe, 0xef]
        let blob = TLVCodec.encodeValue(.bytes(b))
        XCTAssertEqual(blob, [5, 0x04, 0x00, 0x00, 0x00, 0xde, 0xad, 0xbe, 0xef])
        XCTAssertEqual(try TLVCodec.decodeResult(blob), .bytes(b))
    }

    func testHandleByteLayout() throws {
        // tag 6, 4 LE bytes Int32. 0x01020304 → 04 03 02 01.
        let blob = TLVCodec.encodeValue(.handle(0x01020304))
        XCTAssertEqual(blob, [6, 0x04, 0x03, 0x02, 0x01])
        XCTAssertEqual(try TLVCodec.decodeResult(blob), .handle(0x01020304))
    }

    func testErrorByteLayout() throws {
        let blob = TLVCodec.encodeValue(.error("x"))
        XCTAssertEqual(blob, [7, 0x01, 0x00, 0x00, 0x00, 0x78])
        XCTAssertEqual(try TLVCodec.decodeResult(blob), .error("x"))
    }

    func testArgBlobLayout() {
        // [argc:u8] then records. Two args: f64(1.0), i64(2).
        let blob = TLVCodec.encodeArgs([.f64(1.0), .i64(2)])
        XCTAssertEqual(blob[0], 2, "argc prefix")
        let decoded = try? TLVCodec.decodeArgs(blob)
        XCTAssertEqual(decoded, [.f64(1.0), .i64(2)])
    }

    func testDecodeArgsEmptyBlob() throws {
        XCTAssertEqual(try TLVCodec.decodeArgs([]), [])
    }

    func testDecodeArgsTruncatedThrows() {
        // claims 1 arg, no bytes follow.
        XCTAssertThrowsError(try TLVCodec.decodeArgs([0x01]))
        // claims a string of len 10 but supplies none.
        XCTAssertThrowsError(try TLVCodec.decodeArgs([0x01, 0x04, 0x0a, 0x00, 0x00, 0x00]))
    }

    func testDecodeBadTagThrows() {
        XCTAssertThrowsError(try TLVCodec.decodeArgs([0x01, 0x42]))  // tag 0x42 invalid
    }

    func testArgReaderTypeCoercionAndErrors() throws {
        let r = ArgReader([.i64(5), .f64(2.5), .bool(true), .string("hi")])
        XCTAssertEqual(try r.i64(0), 5)
        XCTAssertEqual(try r.f64(0), 5.0, "an i64 widens to f64")
        XCTAssertEqual(try r.f64(1), 2.5)
        XCTAssertEqual(try r.bool(2), true)
        XCTAssertEqual(try r.string(3), "hi")
        XCTAssertThrowsError(try r.string(0), "i64 is not a string")
        XCTAssertThrowsError(try r.handle(0), "i64 is not a handle")
        XCTAssertThrowsError(try r.i64(99), "out-of-range index throws")
        XCTAssertThrowsError(try r.requireArity(2), "arity mismatch throws")
    }
}

// MARK: - HandleTable

final class HandleTableTests: XCTestCase {

    private final class Box { let v: Int; init(_ v: Int) { self.v = v } }

    func testRetainResolveRelease() {
        let t = HandleTable()
        let a = Box(1)
        let h = t.retain(a)
        XCTAssertEqual(t.liveCount, 1)
        XCTAssertTrue(t.resolve(h) === a)
        XCTAssertNotNil(t.resolve(h, as: Box.self))
        t.release(h)
        XCTAssertNil(t.resolve(h))
        XCTAssertEqual(t.liveCount, 0)
    }

    func testHandlesAreMonotonicAndNeverReused() {
        let t = HandleTable()
        let h1 = t.retain(Box(1))
        t.release(h1)
        let h2 = t.retain(Box(2))
        XCTAssertNotEqual(h1, h2, "a freed slot id is NEVER reused (monotonic)")
        XCTAssertNil(t.resolve(h1), "the stale handle resolves to nil, never the new object")
    }

    func testTypeMismatchResolvesNil() {
        let t = HandleTable()
        let h = t.retain(Box(1))
        XCTAssertNil(t.resolve(h, as: NumberFormatter.self),
                     "a wrong-type cast resolves to nil (an ABI mismatch → demote)")
    }

    func testHostHoldsOnlyStrongRef() {
        let t = HandleTable()
        weak var weakBox: Box?
        var h: Int32 = 0
        autoreleasepool {
            let b = Box(7)
            weakBox = b
            h = t.retain(b)
        }
        // The host table is the only strong ref now; the object is still alive.
        XCTAssertNotNil(weakBox, "the host table retains the object")
        XCTAssertNotNil(t.resolve(h))
        t.release(h)
        XCTAssertNil(weakBox, "releasing the handle frees the native object (ARC)")
    }

    func testRemoveAllDropsEverything() {
        let t = HandleTable()
        _ = t.retain(Box(1)); _ = t.retain(Box(2)); _ = t.retain(Box(3))
        XCTAssertEqual(t.liveCount, 3)
        t.removeAll()
        XCTAssertEqual(t.liveCount, 0, "module teardown drops the whole table")
    }

    func testStaleHandleFromUnknownIdResolvesNil() {
        let t = HandleTable()
        XCTAssertNil(t.resolve(99999), "an id never issued resolves to nil")
    }
}

// MARK: - Symbol manifest reader

final class SymbolManifestTests: XCTestCase {

    func testParsesArrayForm() {
        let json = """
        [ { "id": 101, "sig": "PricingEngine.discount(subtotal:Double,tier:Int)->Double",
            "args": [2, 1], "ret": 2 },
          { "id": 201, "sig": "make(String)->NumberFormatter", "args": [4], "ret": 6 } ]
        """
        let m = HostSymbolManifest.parse(json)
        XCTAssertEqual(m.symbols.count, 2)
        XCTAssertEqual(m.declaredIDs, [101, 201])
        let d = m.descriptor(for: 101)
        XCTAssertEqual(d?.argTags, [2, 1])
        XCTAssertEqual(d?.retTag, 2)
        XCTAssertEqual(d?.canonicalSignature.hasPrefix("PricingEngine"), true)
    }

    func testParsesObjectWrappedForm() {
        let json = """
        { "symbols": [ { "id": 7, "canonicalSignature": "f()->Void", "argTags": [], "retTag": 0 } ] }
        """
        let m = HostSymbolManifest.parse(json)
        XCTAssertEqual(m.declaredIDs, [7])
        XCTAssertEqual(m.descriptor(for: 7)?.retTag, 0)
    }

    func testMalformedManifestDegradesToEmpty() {
        XCTAssertTrue(HostSymbolManifest.parse([]).symbols.isEmpty)
        XCTAssertTrue(HostSymbolManifest.parse("not json {{{").symbols.isEmpty)
        XCTAssertTrue(HostSymbolManifest.parse("42").symbols.isEmpty)
        // an entry missing an id is skipped, not fatal.
        let partial = HostSymbolManifest.parse(#"[{"sig":"x"},{"id":5,"sig":"y"}]"#)
        XCTAssertEqual(partial.declaredIDs, [5])
    }

    func testControllerLoadManifest() {
        let bridge = PatchHostBridge()
        bridge.loadManifest([UInt8](#"[{"id":101,"sig":"x","args":[2],"ret":2}]"#.utf8))
        XCTAssertEqual(bridge.currentManifest.declaredIDs, [101])
    }
}
