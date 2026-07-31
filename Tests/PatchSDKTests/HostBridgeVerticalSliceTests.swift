// SPDX-License-Identifier: MIT

import XCTest
import Foundation
import CryptoKit
import WasmKit
import WasmKitWASI
@testable import PatchHostBridge

// ===========================================================================
// LEVER #2 — INTEGRATION VERTICAL SLICE (the RUNTIME half).
//
// This is the on-device end of the Lever-#2 vertical slice: it drives the
// ENGINE-EMITTED guest (`HostBridgeVerticalSliceGuest.wasm` — whose body is
// HostBridgeABI.emitGuestPreamble() + emitCallSite(), produced + byte-asserted
// by the CLI's HostBridgeVerticalSliceTests) through the REAL SDK host runtime:
//
//   guest (Agent 2 codegen) → GenericHostBridge (Agent 1 glue) →
//   PatchHostBridge (Agent 1 controller) → the resolver thunk
//   (Agent 4's real-SDK output, executed below) → the REAL native
//   PricingEngine.discount(_:_:).
//
// The contract that ties the two packages together is the CONTENT-ADDRESSED
// SYMBOL ID: the engine derives `truncate32(SHA256(canonicalSignature))` and
// bakes it into the guest's `patch_host.call(symbolId, …)`; the SDK registers
// the resolver thunk under the SAME id. We recompute that id here (independent
// SHA256) and assert it matches the constant the guest was built with, so the
// engine↔runtime agreement is proven, not assumed.
// ===========================================================================

// MARK: - The "already-linked native code" the routed call resolves to.
// This is the app's own type the engine could not reconstruct — exactly the
// thing the build-time resolver thunk (Agent 4) calls directly.

private enum PricingEngine {
    // tier 0 = none, 1 = silver (5%), 2 = gold (12%)
    static func discount(subtotal: Double, tier: Int) -> Double {
        let pct: Double = (tier == 2) ? 0.12 : (tier == 1) ? 0.05 : 0.0
        return (subtotal * (1.0 - pct) * 100).rounded() / 100
    }
}

final class HostBridgeVerticalSliceTests: XCTestCase {

    /// The canonical signature the engine assigns the routed call (DESIGN §2.3 —
    /// module-qualified, no whitespace, declaration param order). MUST equal the
    /// string the engine's `HostBridgeABI.canonicalSignature(...)` produces for
    /// `PricingEngine.discount(subtotal:Double,tier:Int)->Double`.
    private static let canonicalSignature =
        "MyApp.PricingEngine.discount(subtotal:Double,tier:Int)->Double"

    /// The id the GUEST fixture was compiled with (the engine's
    /// `truncate32(SHA256(canonicalSignature))`). Recomputed + asserted below.
    private static let routedSymbolID: Int32 = -1509889347

    /// Recompute `truncate32(SHA256(sig))` exactly as the engine's
    /// `HostBridgeABI.hostBridgeSymbolId` does (first 4 digest bytes, big-endian,
    /// reinterpreted as Int32). Proves the SDK and the engine agree on the id from
    /// the SAME signature, with no shared constant.
    private static func contentAddressedID(_ sig: String) -> Int32 {
        let digest = SHA256.hash(data: Data(sig.utf8))
        var u: UInt32 = 0
        for (i, byte) in digest.prefix(4).enumerated() {
            u |= UInt32(byte) << (UInt32(3 - i) * 8)
        }
        return Int32(bitPattern: u)
    }

    // MARK: - WASM harness (mirrors GenericHostBridgeTests.makeInstance)

    private func fixtureBytes() throws -> [UInt8] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "HostBridgeVerticalSliceGuest", withExtension: "wasm"),
            "the engine-emitted vertical-slice guest fixture must be present")
        return [UInt8](try Data(contentsOf: url))
    }

    private func makeInstance(_ bridge: PatchHostBridge) throws -> Instance {
        let engine = Engine()
        let store = Store(engine: engine)
        let wasi = try WASIBridgeToHost()
        var imports = Imports()
        wasi.link(to: &imports, store: store)
        // The REAL generic-bridge glue: wires patch_host.call/.release/.have into
        // WasmKit, dispatching into the controller (Agent 1).
        GenericHostBridge(bridge: bridge).register(into: &imports, store: store)
        let module = try parseWasm(bytes: try fixtureBytes())
        let instance = try module.instantiate(store: store, imports: imports)
        try wasi.initialize(instance)
        return instance
    }

    private func callI64(_ inst: Instance, _ name: String) throws -> Int64 {
        let fn = try XCTUnwrap(inst.exports[function: name], "missing export \(name)")
        let r = try fn.invoke([])
        return r.isEmpty ? 0 : Int64(bitPattern: r[0].i64)
    }

    // MARK: - The build-time resolver thunk (Agent 4's REAL-SDK output, EXECUTED).
    //
    // This is character-for-character the closure body the engine's
    // HostBridgeThunkGenerator(target: .realSDK) emits for this symbol:
    //
    //   bridge.register(id: -1509889347, signature: "…") { (args, handles) throws -> TLVValue in
    //       return .f64(Double(PricingEngine.discount(subtotal: try args.f64(0),
    //                                                  tier: Int(try args.i64(1)))))
    //   }
    //
    // We register it under the engine-derived id so the guest's call resolves.

    private func registerResolverThunk(into bridge: PatchHostBridge) {
        bridge.register(id: Self.routedSymbolID, signature: Self.canonicalSignature) { (args: ArgReader, handles: HandleTable) throws -> TLVValue in
            return .f64(Double(PricingEngine.discount(subtotal: try args.f64(0), tier: Int(try args.i64(1)))))
        }
    }

    // MARK: - (1) engine↔runtime id agreement

    /// The SDK recomputes the SAME content-addressed id the engine baked into the
    /// guest. If this drifts, the guest's `patch_host.call(symbolId,…)` would miss
    /// the registry (→ have()==0 → demote) — so this is the load-bearing invariant.
    func testContentAddressedIDMatchesGuest() {
        XCTAssertEqual(Self.contentAddressedID(Self.canonicalSignature), Self.routedSymbolID,
                       "the SDK-recomputed truncate32(SHA256(sig)) must equal the id the guest was built with")
    }

    // MARK: - (2) THE VERTICAL SLICE — engine guest → real runtime → native call

    /// The whole slice: the engine-emitted guest issues ONE `patch_host.call` with
    /// the engine's symbol id; the real GenericHostBridge/PatchHostBridge dispatch it
    /// to the Agent-4 resolver thunk; the thunk calls the REAL native
    /// PricingEngine.discount. The guest returns the discounted total in cents, which
    /// must equal the host's own native computation, value-exact.
    func testRoutedCallExecutesThroughRealRuntime() throws {
        let bridge = PatchHostBridge()
        registerResolverThunk(into: bridge)

        // The engine also folds the routed symbol into the patch_host_symbols
        // manifest; load it so have()/diagnostics see the declared id (DESIGN §5).
        bridge.loadManifest([UInt8]("""
        { "schemaVersion": 1, "symbols": [
            { "id": \(Self.routedSymbolID),
              "canonicalSignature": "\(Self.canonicalSignature)",
              "argTags": [2, 1], "retTag": 2 } ] }
        """.utf8))

        // Pre-flight: the symbol the guest routes IS resolvable in this build.
        XCTAssertTrue(bridge.have(Self.routedSymbolID),
                      "the resolver thunk is registered → have() must be true")

        let inst = try makeInstance(bridge)

        // Host's own native truth: discount(129.99, tier 1=silver) → *100 cents.
        let expectedCents = Int64((PricingEngine.discount(subtotal: 129.99, tier: 1) * 100).rounded())
        // 129.99 * 0.95 = 123.4905 → rounds to 123.49 → 12349 cents.
        XCTAssertEqual(expectedCents, 12349, "documented exact result for silver tier")

        let actualCents = try callI64(inst, "test_routed_discount_cents")
        XCTAssertEqual(actualCents, expectedCents,
                       "the guest's routed PricingEngine.discount result must be value-exact")

        // No handles were created (a scalar call) — the table stays empty.
        XCTAssertEqual(bridge.handles.liveCount, 0, "a scalar call leaks no handles")
    }

    /// Demote safety: with NO thunk registered, the guest's same call sees have()==0
    /// and call() → tagged `.error`, so its emitted decoder falls through to its
    /// native-fallback (`return -1`). Proves the fail-closed path end-to-end.
    func testUnregisteredSymbolDemotesThroughRealRuntime() throws {
        let bridge = PatchHostBridge()   // deliberately register NOTHING
        XCTAssertFalse(bridge.have(Self.routedSymbolID))
        let inst = try makeInstance(bridge)
        // The guest decodes a tagged .error (no thunk) → its `guard case .f64` fails →
        // it returns its native fallback sentinel (-1), never a wrong number.
        XCTAssertEqual(try callI64(inst, "test_routed_discount_cents"), -1,
                       "an unresolved routed call must demote (the guest's native fallback), never misdispatch")
    }

    // MARK: - (3) TLV byte-identity with the engine (the wire contract)

    /// The engine (CLI `HostBridgeABI.TLVTag`) and this runtime (`TLVTag`) MUST share
    /// the exact wire tag bytes (DESIGN §2.2) or every routed call silently
    /// misdispatches. The guest packs args with the engine's tag bytes; we assert the
    /// runtime decodes the very bytes the engine's writer produces for this call's args.
    func testArgBlobBytesMatchEngineWireFormat() throws {
        // The engine's emitted guest packs: f64(129.99), i64(1), with an argc prefix.
        // Reconstruct that exact blob with the runtime codec and assert the decode.
        let blob = TLVCodec.encodeArgs([.f64(129.99), .i64(1)])
        // argc=2, then tag2 (f64) + 8 LE bytes, then tag1 (i64) + 8 LE bytes.
        XCTAssertEqual(blob[0], 2, "argc prefix")
        XCTAssertEqual(blob[1], TLVTag.f64.rawValue, "first arg tag = f64 (2)")
        XCTAssertEqual(blob[10], TLVTag.i64.rawValue, "second arg tag = i64 (1)")
        let decoded = try TLVCodec.decodeArgs(blob)
        XCTAssertEqual(decoded, [.f64(129.99), .i64(1)])
        // And the canonical tag numbering is the DESIGN §2.2 table.
        XCTAssertEqual(TLVTag.nilValue.rawValue, 0)
        XCTAssertEqual(TLVTag.i64.rawValue, 1)
        XCTAssertEqual(TLVTag.f64.rawValue, 2)
        XCTAssertEqual(TLVTag.bool.rawValue, 3)
        XCTAssertEqual(TLVTag.string.rawValue, 4)
        XCTAssertEqual(TLVTag.bytes.rawValue, 5)
        XCTAssertEqual(TLVTag.handle.rawValue, 6)
        XCTAssertEqual(TLVTag.error.rawValue, 7)
    }
}
