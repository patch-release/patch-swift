import XCTest
import Foundation
@testable import PatchSDK

/// Phase-1b resource overlay (SDK side): the overlay-chunk + `POVR` artifact codecs,
/// `ModuleStorage` overlay caching, activation strip+install, the named-lookup
/// redirection (override-first / bundle-fallback), and rollback restore.
final class ResourceOverlayTests: XCTestCase {

    // MARK: helpers

    private func tempDir() -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("patch-overlay-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func marshalBytes() throws -> [UInt8] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "MarshalFixture.release", withExtension: "wasm"))
        return [UInt8](try Data(contentsOf: url))
    }

    private func sampleTable() -> PatchResourceOverlay.Table {
        var t = PatchResourceOverlay.Table()
        t.colors["brand"] = PatchResourceOverlay.Color(
            r: 0.04, g: 0.48, b: 1.0, a: 1.0,
            dark: PatchResourceOverlay.RGBA(r: 0.2, g: 0.57, b: 1.0))
        t.strings[""] = ["welcome": PatchResourceOverlay.StringOverride(key: "welcome", value: "Welcome back!")]
        t.strings["fr"] = ["welcome": PatchResourceOverlay.StringOverride(key: "welcome", value: "Bon retour !")]
        return t
    }

    // MARK: - Codec round-trip (must match the CLI byte-for-byte)

    func testOverlayChunkRoundTrip() throws {
        let table = sampleTable()
        let bytes = PatchResourceOverlay.encode(table)
        XCTAssertTrue(PatchResourceOverlay.isOverlay(bytes))
        XCTAssertEqual(try XCTUnwrap(PatchResourceOverlay.decode(bytes)), table)
    }

    func testArtifactWrapperRoundTrip() throws {
        let inner: [UInt8] = [0x00, 0x61, 0x73, 0x6d, 1, 0, 0, 0]
        let overlay = PatchResourceOverlay.encode(sampleTable())
        let wrapped = PatchOverlayArtifact.encode(inner: inner, overlay: overlay)
        let decoded = try XCTUnwrap(PatchOverlayArtifact.decode(wrapped))
        XCTAssertEqual(decoded.inner, inner)
        XCTAssertEqual(decoded.overlay, overlay)
    }

    func testRawWasmIsNotArtifact() {
        XCTAssertNil(PatchOverlayArtifact.decode([0x00, 0x61, 0x73, 0x6d, 1, 0, 0, 0]))
    }

    // MARK: - Locale-aware string resolution

    func testStringResolvesWithLocaleFallback() {
        let t = sampleTable()
        XCTAssertEqual(t.string(forKey: "welcome", table: nil, locale: "fr"), "Bon retour !")
        XCTAssertEqual(t.string(forKey: "welcome", table: nil, locale: "fr-CA"), "Bon retour !")  // prefix
        XCTAssertEqual(t.string(forKey: "welcome", table: nil, locale: "es"), "Welcome back!")    // base
        XCTAssertEqual(t.string(forKey: "welcome", table: nil, locale: nil), "Welcome back!")
        XCTAssertNil(t.string(forKey: "absent", table: nil, locale: "fr"))
    }

    func testStringTableScoping() {
        var t = PatchResourceOverlay.Table()
        t.strings[""] = ["k": PatchResourceOverlay.StringOverride(key: "k", value: "v", table: "Onboarding")]
        XCTAssertEqual(t.string(forKey: "k", table: "Onboarding", locale: nil), "v")
        // A request for a DIFFERENT pinned table misses (the override pins "Onboarding").
        XCTAssertNil(t.string(forKey: "k", table: "Other", locale: nil))
        // A request with no table still matches (best-effort).
        XCTAssertEqual(t.string(forKey: "k", table: nil, locale: nil), "v")
    }

    // MARK: - ModuleStorage overlay caching + pruning

    func testStorageCachesOverlaySidecarFromWrappedArtifact() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let s = try ModuleStorage(appKey: "ov", baseDirectory: dir)

        let inner: [UInt8] = [0x00, 0x61, 0x73, 0x6d, 1, 0, 0, 0]
        let overlay = PatchResourceOverlay.encode(sampleTable())
        let wrapped = PatchOverlayArtifact.encode(inner: inner, overlay: overlay)

        try s.installCurrent(version: "1.0.0", sha256: "sha", bytes: wrapped)
        // The full wrapped artifact round-trips as the module bytes…
        XCTAssertEqual(try s.currentBytes(), wrapped)
        // …and the extracted overlay sidecar is cached + decodes back.
        let chunk = try XCTUnwrap(s.currentOverlayChunk())
        XCTAssertEqual(chunk, overlay)
        XCTAssertEqual(try XCTUnwrap(PatchResourceOverlay.decode(chunk)), sampleTable())
    }

    func testStorageOverlaySidecarSurvivesReopen() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let overlay = PatchResourceOverlay.encode(sampleTable())
        let wrapped = PatchOverlayArtifact.encode(inner: [0x00, 0x61, 0x73, 0x6d], overlay: overlay)
        let s1 = try ModuleStorage(appKey: "ov2", baseDirectory: dir)
        try s1.installCurrent(version: "2.0.0", sha256: "sha", bytes: wrapped)

        let s2 = try ModuleStorage(appKey: "ov2", baseDirectory: dir)
        XCTAssertEqual(s2.currentOverlayChunk(), overlay)
    }

    func testOverlayFreeModuleClearsSidecar() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let s = try ModuleStorage(appKey: "ov3", baseDirectory: dir)
        // v1 carries an overlay; v2 (plain wasm) replaces it as current.
        let wrapped = PatchOverlayArtifact.encode(
            inner: [0x00, 0x61, 0x73, 0x6d], overlay: PatchResourceOverlay.encode(sampleTable()))
        try s.installCurrent(version: "1.0.0", sha256: "v1", bytes: wrapped)
        XCTAssertNotNil(s.overlayChunk(version: "1.0.0"))
        try s.installCurrent(version: "2.0.0", sha256: "v2", bytes: [0x00, 0x61, 0x73, 0x6d, 9])
        // v2 current has no overlay; v1 is now previous and keeps its sidecar.
        XCTAssertNil(s.currentOverlayChunk())
        XCTAssertNotNil(s.overlayChunk(version: "1.0.0"))
    }

    func testInstallOverlayManualAndPrune() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let s = try ModuleStorage(appKey: "ov4", baseDirectory: dir)
        let overlay = PatchResourceOverlay.encode(sampleTable())
        s.installOverlay(version: "3.0.0", overlayChunk: overlay)
        XCTAssertEqual(s.overlayChunk(version: "3.0.0"), overlay)
        s.installOverlay(version: "3.0.0", overlayChunk: nil)  // clears
        XCTAssertNil(s.overlayChunk(version: "3.0.0"))
    }

    // MARK: - Activation: strip the wrapper, install the overlay, run the inner module

    func testActivateWrappedArtifactInstallsOverlayAndRunsModule() throws {
        let patch = Patch()
        patch.bridges.registerDefaults()
        defer { patch.deactivate() }

        let inner = try marshalBytes()
        let wrapped = PatchOverlayArtifact.encode(
            inner: inner, overlay: PatchResourceOverlay.encode(sampleTable()))

        try patch.activate(bytes: wrapped)
        // The INNER module instantiated + runs (proves the wrapper was stripped).
        XCTAssertTrue(patch.hasActiveModule)
        XCTAssertEqual(Int64(bitPattern: try patch.call("add_i64", [.i64(40), .i64(2)])[0].i64), 42)
        // The overlay is now active + queryable.
        XCTAssertTrue(patch.hasResourceOverlay)
        let brand = try XCTUnwrap(patch.overlayColor(named: "brand"))
        XCTAssertEqual(brand.b, 1.0, accuracy: 1e-9)
        XCTAssertEqual(patch.overlayLocalizedString(forKey: "welcome", locale: "fr"), "Bon retour !")
    }

    func testActivatePlainWasmHasNoOverlay() throws {
        let patch = Patch()
        patch.bridges.registerDefaults()
        defer { patch.deactivate() }
        try patch.activate(bytes: try marshalBytes())   // a RAW wasm, no wrapper
        XCTAssertTrue(patch.hasActiveModule)
        XCTAssertFalse(patch.hasResourceOverlay)
        XCTAssertNil(patch.overlayColor(named: "brand"))
    }

    func testDeactivateClearsOverlay() throws {
        let patch = Patch()
        patch.bridges.registerDefaults()
        let wrapped = PatchOverlayArtifact.encode(
            inner: try marshalBytes(), overlay: PatchResourceOverlay.encode(sampleTable()))
        try patch.activate(bytes: wrapped)
        XCTAssertTrue(patch.hasResourceOverlay)
        patch.deactivate()
        XCTAssertFalse(patch.hasResourceOverlay)
        XCTAssertNil(patch.overlayColor(named: "brand"))
    }

    // MARK: - Redirect: override-first, bundle-fallback, rollback restore

    func testRedirectReturnsOverrideElseFallsThrough() {
        let redirect = ResourceOverlayRedirect.shared
        redirect.setActiveOverlay(sampleTable())
        defer { redirect.setActiveOverlay(nil) }

        // Color present → returns the override components.
        let light = redirect.colorComponents(named: "brand", dark: false)
        XCTAssertNotNil(light)
        XCTAssertEqual(light?.r ?? 0, 0.04, accuracy: 1e-9)
        let dark = redirect.colorComponents(named: "brand", dark: true)
        XCTAssertEqual(dark?.r ?? 0, 0.2, accuracy: 1e-9)
        // Color absent → nil (caller falls through to the bundle).
        XCTAssertNil(redirect.colorComponents(named: "not-overridden", dark: false))

        // String present → override; absent → nil.
        XCTAssertEqual(redirect.localizedString(forKey: "welcome", table: nil, locale: "fr"), "Bon retour !")
        XCTAssertNil(redirect.localizedString(forKey: "absent", table: nil, locale: nil))
    }

    /// Rollback restores the PRIOR overlay (or clears it) in lock-step with the module.
    func testHotSwapRollbackRestoresPriorOverlay() throws {
        let patch = Patch()
        patch.bridges.registerDefaults()
        defer { patch.deactivate(); ResourceOverlayRedirect.shared.setActiveOverlay(nil) }

        // Activate a GOOD wrapped artifact (overlay A).
        var tableA = PatchResourceOverlay.Table()
        tableA.colors["brand"] = PatchResourceOverlay.Color(r: 0.1, g: 0.2, b: 0.3)
        let goodWrapped = PatchOverlayArtifact.encode(
            inner: try marshalBytes(), overlay: PatchResourceOverlay.encode(tableA))
        try patch.activate(bytes: goodWrapped)
        XCTAssertEqual(patch.overlayColor(named: "brand")?.r ?? 0, 0.1, accuracy: 1e-9)

        // Hot-swap to a BROKEN artifact (overlay B + a non-wasm inner that can't
        // instantiate) — it must roll back, restoring overlay A.
        var tableB = PatchResourceOverlay.Table()
        tableB.colors["brand"] = PatchResourceOverlay.Color(r: 0.9, g: 0.9, b: 0.9)
        let brokenWrapped = PatchOverlayArtifact.encode(
            inner: [0x00, 0x61, 0x73, 0x6d, 0xDE, 0xAD, 0xBE, 0xEF],  // garbage "wasm"
            overlay: PatchResourceOverlay.encode(tableB))
        XCTAssertThrowsError(try patch.hotSwap(bytes: brokenWrapped))

        // Overlay A is restored — NOT B — and the good module still runs.
        XCTAssertEqual(patch.overlayColor(named: "brand")?.r ?? 0, 0.1, accuracy: 1e-9)
        XCTAssertEqual(ResourceOverlayRedirect.shared.colorComponents(named: "brand", dark: false)?.r ?? 0,
                       0.1, accuracy: 1e-9)
        XCTAssertEqual(Int64(bitPattern: try patch.call("add_i64", [.i64(1), .i64(2)])[0].i64), 3)
    }

    /// Manual activation API installs + clears the redirection without a module.
    func testManualOverlayActivation() {
        let patch = Patch()
        patch.activateResourceOverlay(sampleTable())
        defer { patch.activateResourceOverlay(nil) }
        XCTAssertTrue(patch.hasResourceOverlay)
        XCTAssertEqual(patch.overlayLocalizedString(forKey: "welcome", locale: "fr"), "Bon retour !")
        patch.activateResourceOverlay(nil)
        XCTAssertFalse(patch.hasResourceOverlay)
    }
}

#if canImport(ObjectiveC)
import ObjectiveC

/// The ObjC swizzle path is exercised separately because it mutates PROCESS-WIDE
/// state (the swizzled `Bundle.localizedString` IMP stays installed for the process
/// lifetime). It proves the swizzle redirects an overridden key and falls through to
/// the bundle for an un-overridden one. (UIColor/UIImage swizzles need UIKit, absent
/// on the macOS test host — they are covered by the redirect-lookup logic above and
/// build under `#if canImport(UIKit)`.)
final class ResourceOverlaySwizzleTests: XCTestCase {

    func testBundleLocalizedStringSwizzleOverridesAndFallsThrough() {
        // Install the swizzles via the public activation path.
        let patch = Patch()
        var t = PatchResourceOverlay.Table()
        // Use the device's preferred locale so the swizzle (which resolves against
        // Locale.preferredLanguages) finds the override regardless of CI locale.
        let loc = Locale.preferredLanguages.first ?? ""
        t.strings[loc] = ["patch_overlay_test_key":
            PatchResourceOverlay.StringOverride(key: "patch_overlay_test_key", value: "OVERRIDDEN")]
        t.strings[""] = ["patch_overlay_test_key":
            PatchResourceOverlay.StringOverride(key: "patch_overlay_test_key", value: "OVERRIDDEN")]
        patch.activateResourceOverlay(t)
        defer { patch.activateResourceOverlay(nil) }

        // Overridden key → the override value (through NSLocalizedString → swizzled
        // Bundle.localizedString).
        let overridden = NSLocalizedString("patch_overlay_test_key", comment: "")
        XCTAssertEqual(overridden, "OVERRIDDEN")

        // Un-overridden key → the bundle's behavior: a missing key returns the key
        // itself (the override table doesn't carry it, so it falls through).
        let passthrough = NSLocalizedString("patch_overlay_absent_key_xyz", comment: "")
        XCTAssertEqual(passthrough, "patch_overlay_absent_key_xyz")

        // After clearing the overlay, even the previously-overridden key falls through.
        patch.activateResourceOverlay(nil)
        let afterClear = NSLocalizedString("patch_overlay_test_key", comment: "")
        XCTAssertEqual(afterClear, "patch_overlay_test_key")
    }
}
#endif
