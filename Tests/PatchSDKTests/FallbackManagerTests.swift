import XCTest
import WasmKit
@testable import PatchSDK

/// D2 — FallbackManager: the graceful-degradation chain
/// current → previous → bundled → disabled. The core safety mechanism: a bad
/// module must never crash the app; it walks the chain until something activates
/// (or lands on "disabled"). Tested with both injected activation (to deciside
/// exactly which slot is "bad") and a real corrupt WASM blob.
final class FallbackManagerTests: XCTestCase {

    private func tempStorage() throws -> (ModuleStorage, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("patch-fallback-\(UUID().uuidString)")
        return (try ModuleStorage(appKey: "fb", baseDirectory: dir), dir)
    }

    /// An activation closure that rejects any module whose first byte is in
    /// `badMarkers`, recording what was activated.
    private final class Activator: @unchecked Sendable {
        let badMarkers: Set<UInt8>
        private let lock = NSLock()
        private(set) var activeMarker: UInt8?
        private(set) var deactivated = false
        init(bad: Set<UInt8>) { self.badMarkers = bad }
        func activate(_ bytes: [UInt8]) throws {
            lock.lock(); defer { lock.unlock() }
            guard let first = bytes.first, !badMarkers.contains(first) else {
                struct Bad: Error {}; throw Bad()
            }
            activeMarker = first; deactivated = false
        }
        func deactivate() { lock.lock(); deactivated = true; activeMarker = nil; lock.unlock() }
    }

    // Marker bytes identify each slot's module.
    private let curMark: UInt8 = 10
    private let prevMark: UInt8 = 20
    private let bunMark: UInt8 = 30

    private func seed(_ s: ModuleStorage, current: Bool = true, previous: Bool = true, bundled: Bool = true) throws {
        if previous { try s.installCurrent(version: "prev", sha256: "p", bytes: [prevMark, 0, 0]) }
        if current { try s.installCurrent(version: "cur", sha256: "c", bytes: [curMark, 0, 0]) }
        // After two installs: current=cur, previous=prev.
        if bundled { s.registerBundled(version: "bundled", bytes: [bunMark, 0, 0]) }
    }

    // MARK: - Happy path: current activates

    func testCurrentActivatesWhenHealthy() throws {
        let (s, dir) = try tempStorage(); defer { try? FileManager.default.removeItem(at: dir) }
        try seed(s)
        let act = Activator(bad: [])
        let fb = FallbackManager(storage: s, activate: act.activate, deactivate: act.deactivate)
        let state = fb.activateBest()
        XCTAssertEqual(state, .current(version: "cur"))
        XCTAssertEqual(act.activeMarker, curMark)
    }

    // MARK: - current bad → previous

    func testBadCurrentFallsToPrevious() throws {
        let (s, dir) = try tempStorage(); defer { try? FileManager.default.removeItem(at: dir) }
        try seed(s)
        let act = Activator(bad: [curMark])  // current traps
        let fb = FallbackManager(storage: s, activate: act.activate, deactivate: act.deactivate)
        let state = fb.activateBest()
        XCTAssertEqual(state, .previous(version: "prev"))
        XCTAssertEqual(act.activeMarker, prevMark)
        // The bad current should have been dropped and previous promoted.
        XCTAssertEqual(s.currentVersion, "prev")
    }

    // MARK: - current + previous bad → bundled

    func testBadCurrentAndPreviousFallsToBundled() throws {
        let (s, dir) = try tempStorage(); defer { try? FileManager.default.removeItem(at: dir) }
        try seed(s)
        let act = Activator(bad: [curMark, prevMark])
        let fb = FallbackManager(storage: s, activate: act.activate, deactivate: act.deactivate)
        let state = fb.activateBest()
        XCTAssertEqual(state, .bundled(version: "bundled"))
        XCTAssertEqual(act.activeMarker, bunMark)
    }

    // MARK: - everything bad → disabled (native only, no crash)

    func testAllSlotsBadFallsToDisabled() throws {
        let (s, dir) = try tempStorage(); defer { try? FileManager.default.removeItem(at: dir) }
        try seed(s)
        let act = Activator(bad: [curMark, prevMark, bunMark])
        let fb = FallbackManager(storage: s, activate: act.activate, deactivate: act.deactivate)
        let state = fb.activateBest()
        XCTAssertEqual(state, .disabled)
        XCTAssertTrue(act.deactivated, "disabled must deactivate any OTA module")
        XCTAssertNil(act.activeMarker)
        // Trail records every attempt down the chain.
        let slots = fb.trail.map { $0.slot }
        XCTAssertEqual(slots, [.current, .previous, .bundled, .disabled])
    }

    func testNoModulesAtAllIsDisabledNotCrash() throws {
        let (s, dir) = try tempStorage(); defer { try? FileManager.default.removeItem(at: dir) }
        // Empty storage, no bundled.
        let act = Activator(bad: [])
        let fb = FallbackManager(storage: s, activate: act.activate, deactivate: act.deactivate)
        XCTAssertEqual(fb.activateBest(), .disabled)
    }

    // MARK: - recoverFromBadCurrent (runtime trap after activation)

    func testRecoverFromBadCurrentPromotesPrevious() throws {
        let (s, dir) = try tempStorage(); defer { try? FileManager.default.removeItem(at: dir) }
        try seed(s)
        let act = Activator(bad: [])  // both previous and bundled are fine
        let fb = FallbackManager(storage: s, activate: act.activate, deactivate: act.deactivate)
        let state = fb.recoverFromBadCurrent()
        XCTAssertEqual(state, .previous(version: "prev"))
        XCTAssertEqual(s.currentVersion, "prev")
    }

    // MARK: - probe rejects a module that activates but traps on call

    func testProbeRejectsModuleThatActivatesButTraps() throws {
        let (s, dir) = try tempStorage(); defer { try? FileManager.default.removeItem(at: dir) }
        try seed(s)
        let act = Activator(bad: [])  // activation always succeeds
        // Probe fails while the current marker is active (simulating a runtime
        // trap), reading the just-activated marker straight off the activator.
        let curMark = self.curMark
        let fb = FallbackManager(
            storage: s, activate: act.activate, deactivate: act.deactivate,
            probe: {
                if act.activeMarker == curMark { struct Trap: Error {}; throw Trap() }
            })
        let state = fb.activateBest()
        // current activates but the probe traps → fall to previous.
        XCTAssertEqual(state, .previous(version: "prev"))
    }

    // MARK: - Real corrupt WASM: instantiation failure walks the chain

    func testRealCorruptWasmFallsToBundledRealModule() throws {
        let (s, dir) = try tempStorage(); defer { try? FileManager.default.removeItem(at: dir) }
        // current = garbage bytes (won't parse/instantiate).
        let garbage: [UInt8] = [0x00, 0x61, 0x73, 0x6d, 0xFF, 0xFF, 0xFF, 0xFF]
        try s.installCurrent(version: "corrupt", sha256: "x", bytes: garbage)
        // bundled = a real, valid wasm module.
        let realURL = try XCTUnwrap(Bundle.module.url(forResource: "MarshalFixture.release", withExtension: "wasm"))
        let realBytes = [UInt8](try Data(contentsOf: realURL))
        s.registerBundled(version: "bundled-real", bytes: realBytes)

        // Activate via the REAL Patch runtime — corrupt fails to instantiate.
        let patch = Patch()
        let fb = FallbackManager(
            storage: s,
            activate: { try patch.activate(bytes: $0) },
            deactivate: { patch.deactivate() })
        let state = fb.activateBest()
        XCTAssertEqual(state, .bundled(version: "bundled-real"))
        XCTAssertTrue(patch.hasActiveModule)
        // The real bundled module runs.
        XCTAssertEqual(Int64(bitPattern: try patch.call("add_i64", [.i64(1), .i64(2)])[0].i64), 3)
    }
}
