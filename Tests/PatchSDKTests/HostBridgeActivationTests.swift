// SPDX-License-Identifier: MIT

import XCTest
import Foundation
import CryptoKit
import WasmKit
@testable import PatchSDK
@testable import PatchHostBridge

// ===========================================================================
// LEVER #2 — SDK ACTIVATION-PATH PROOF.
//
// The companion to HostBridgeVerticalSliceTests (which drove the engine-emitted
// guest through a HAND-BUILT WasmKit instance). This proves the SAME guest routes
// correctly through the REAL `Patch` MODULE-ACTIVATION path:
//
//   Patch.onRegisterHostBridges(thunk)          // the app's generated registrar
//        → Patch.activate(bytes:)               // the real activation lifecycle
//          → instantiateModuleSet → composedHostImports()
//             → GenericHostBridge(bridge: patch.hostBridge) wired into the import set
//        → patch.call("test_routed_discount_cents")   // a live guest export call
//          → the guest issues patch_host.call(symbolId,…)
//             → patch.hostBridge dispatches → the resolver thunk → real native code
//
// i.e. the SDK AUTOMATICALLY serves the generic bridge for a shipped module — no
// hand-built instance, no manual GenericHostBridge.register at the call site.
//
// Uses an ISOLATED `Patch()` instance (not the process singleton) so the test
// owns its module set + host-bridge lifetime cleanly.
// ===========================================================================

final class HostBridgeActivationTests: XCTestCase {

    // The app's own already-linked native type the routed call resolves to — the
    // thing the engine couldn't reconstruct, exactly what the build-time resolver
    // thunk calls directly. (Same as the vertical-slice test.)
    private enum PricingEngine {
        static func discount(subtotal: Double, tier: Int) -> Double {
            let pct: Double = (tier == 2) ? 0.12 : (tier == 1) ? 0.05 : 0.0
            return (subtotal * (1.0 - pct) * 100).rounded() / 100
        }
    }

    private static let canonicalSignature =
        "MyApp.PricingEngine.discount(subtotal:Double,tier:Int)->Double"
    private static let routedSymbolID: Int32 = -1509889347

    private func fixtureBytes() throws -> [UInt8] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "HostBridgeVerticalSliceGuest", withExtension: "wasm"),
            "the engine-emitted vertical-slice guest fixture must be present")
        return [UInt8](try Data(contentsOf: url))
    }

    // The generated app registrar — character-for-character the body the engine's
    // HostBridgeThunkGenerator(target: .realSDK) emits as `__patchRegisterHostBridges`,
    // here closed over the test's `PricingEngine`. The app installs ONE such function
    // via `Patch.shared.onRegisterHostBridges(__patchRegisterHostBridges)`.
    private static let appRegistrar: @Sendable (PatchHostBridge) -> Void = { bridge in
        bridge.register(id: routedSymbolID, signature: canonicalSignature) { (args, _) throws -> TLVValue in
            .f64(Double(PricingEngine.discount(subtotal: try args.f64(0), tier: Int(try args.i64(1)))))
        }
    }

    private func callI64(_ patch: Patch, _ name: String) throws -> Int64 {
        let results = try patch.call(name)
        return results.isEmpty ? 0 : Int64(bitPattern: results[0].i64)
    }

    // MARK: - (1) The activation-path vertical slice

    /// Register the resolver thunk via the PUBLIC app-facing hand-off, activate the
    /// shipped module through the REAL `Patch.activate` lifecycle, and assert the
    /// guest's routed `PricingEngine.discount` call returns the value-exact result —
    /// proving the SDK automatically wires + serves the generic bridge on activation.
    func testRoutedCallExecutesThroughActivationPath() throws {
        let patch = Patch()
        defer { patch.deactivate() }

        // (a) The app installs its generated registrar ONCE (as it would at configure).
        patch.onRegisterHostBridges(Self.appRegistrar)

        // (b) Activate the shipped module through the real lifecycle. This wires the
        //     generic bridge (backed by patch.hostBridge) into the instance's imports
        //     AND re-runs the registrar + loads the manifest for the new epoch.
        try patch.activate(bytes: try fixtureBytes())

        // The registrar primed the shared bridge → the routed id is resolvable.
        XCTAssertTrue(patch.hostBridge.have(Self.routedSymbolID),
                      "the activation path must re-run the app registrar → have() true")

        // (c) Drive the guest export through the SDK's normal call path. The guest
        //     issues patch_host.call(...) which the AUTOMATICALLY-wired generic bridge
        //     dispatches to the resolver thunk → the real native PricingEngine.discount.
        let expectedCents = Int64((PricingEngine.discount(subtotal: 129.99, tier: 1) * 100).rounded())
        XCTAssertEqual(expectedCents, 12349, "documented exact result for silver tier")
        XCTAssertEqual(try callI64(patch, "test_routed_discount_cents"), expectedCents,
                       "the routed call must round-trip value-exact through the activation path")

        // A scalar call leaks no handles.
        XCTAssertEqual(patch.hostBridge.handles.liveCount, 0, "a scalar call leaks no handles")
    }

    // MARK: - (2) Demote-safe: no registrar installed

    /// With NO app registrar installed, activation leaves the registry empty, the
    /// guest's same call sees have()==0 → tagged `.error`, and its emitted decoder
    /// falls through to its native fallback (-1). Proves a module that ships the
    /// generic bridge but whose thunks the app didn't compile in demotes fail-closed
    /// through the real activation path.
    func testUnregisteredRoutedCallDemotesThroughActivationPath() throws {
        let patch = Patch()
        defer { patch.deactivate() }

        // Deliberately install NOTHING.
        try patch.activate(bytes: try fixtureBytes())

        XCTAssertFalse(patch.hostBridge.have(Self.routedSymbolID),
                       "no registrar → the routed id is unresolvable")
        XCTAssertEqual(try callI64(patch, "test_routed_discount_cents"), -1,
                       "an unresolved routed call must demote (the guest's native fallback), never misdispatch")
    }

    // MARK: - (3) The manifest cross-check loads on activation

    /// Loading the engine's `patch_host_symbols` manifest (here installed directly,
    /// as the fixture ships none as an export) records the declared routed id so the
    /// runtime's `have()`/diagnostics see the module's intent. The registry is what
    /// resolution actually uses, but the manifest is the declared-id cross-check.
    func testManifestDeclaresRoutedSymbolAfterLoad() throws {
        let patch = Patch()
        defer { patch.deactivate() }
        patch.onRegisterHostBridges(Self.appRegistrar)
        try patch.activate(bytes: try fixtureBytes())

        // The fixture exports no `patch_host_symbols`, so the activation-loaded manifest
        // is empty — but the SDK's loadManifest path is what would populate it for a
        // real engine module. Drive it directly to prove the cross-check.
        XCTAssertTrue(patch.hostBridge.currentManifest.declaredIDs.isEmpty,
                      "the fixture ships no manifest export → activation loads an empty one")
        patch.hostBridge.loadManifest([UInt8]("""
        { "schemaVersion": 1, "symbols": [
            { "id": \(Self.routedSymbolID),
              "canonicalSignature": "\(Self.canonicalSignature)",
              "argTags": [2, 1], "retTag": 2 } ] }
        """.utf8))
        XCTAssertTrue(patch.hostBridge.currentManifest.declaredIDs.contains(Self.routedSymbolID),
                      "the loaded manifest must declare the routed id")
    }

    // MARK: - (4) Per-epoch teardown: handles cleaned up

    /// `deactivate()` tears the shared bridge down — every live handle AND the
    /// registry are dropped. Proves the per-epoch handle-table lifetime maps to the
    /// module-set lifetime (a stale handle from a prior epoch can never resolve).
    func testTeardownClearsHandleTableAndRegistry() throws {
        let patch = Patch()
        patch.onRegisterHostBridges(Self.appRegistrar)
        try patch.activate(bytes: try fixtureBytes())

        // Seed a live handle to simulate a by-reference routed call having retained a
        // native object during the epoch, plus confirm the registry is populated.
        let h = patch.hostBridge.handles.retain(NSObject())
        XCTAssertGreaterThan(h, 0)
        XCTAssertEqual(patch.hostBridge.handles.liveCount, 1, "the retained handle is live")
        XCTAssertTrue(patch.hostBridge.have(Self.routedSymbolID), "registry primed on activation")

        // Drop the module set → full host-bridge teardown.
        patch.deactivate()

        XCTAssertEqual(patch.hostBridge.handles.liveCount, 0,
                       "deactivate must drop every live handle (no cross-epoch leak)")
        XCTAssertFalse(patch.hostBridge.have(Self.routedSymbolID),
                       "deactivate clears the registry; a re-activation re-primes it")
    }

    // MARK: - (5) Re-activation re-primes the registry from the same registrar

    /// A mid-session module swap (deactivate → re-activate) re-runs the installed
    /// registrar, so the compiled-in thunks survive a patch epoch change. Proves the
    /// thunk lifetime is app-binary-scoped (re-derived per epoch), not lost on swap.
    func testReactivationRePrimesRegistry() throws {
        let patch = Patch()
        defer { patch.deactivate() }
        patch.onRegisterHostBridges(Self.appRegistrar)

        try patch.activate(bytes: try fixtureBytes())
        XCTAssertEqual(try callI64(patch, "test_routed_discount_cents"), 12349)

        // Simulate a new patch epoch: re-activate the same module set. The registrar
        // is re-run automatically → the routed call still resolves.
        try patch.activate(bytes: try fixtureBytes())
        XCTAssertTrue(patch.hostBridge.have(Self.routedSymbolID),
                      "re-activation must re-prime the registry from the installed registrar")
        XCTAssertEqual(try callI64(patch, "test_routed_discount_cents"), 12349,
                       "the routed call resolves again after a module-set swap")
    }
}
