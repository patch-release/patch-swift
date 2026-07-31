// SPDX-License-Identifier: MIT

import XCTest
@testable import PatchSDK

/// Regression tests for the staged-rollout bucketing bug.
///
/// Before `PatchDeviceIDStore`, `PatchConfiguration.deviceID` defaulted to `nil`,
/// nothing populated it, and the wire payload fell back to the literal `"anon"` —
/// so every device in an app onboarded by `patchcli init` reported the SAME id.
/// The backend buckets with `sha256(device_id + version) % 100`, so identical ids
/// mean an identical bucket: a percentage rollout degenerated into a fleet-wide
/// all-or-nothing coin flip per version.
///
/// The load-bearing assertion here is `testDistinctInstallsGetDistinctIDs` — the
/// bucketer itself is server-side, but distinct ids are the necessary condition
/// for a percentage rollout to spread at all.
final class DeviceIdentityTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "patchsdk.tests.deviceid.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Minting + persistence

    func testResolveMintsANonEmptyID() {
        let id = PatchDeviceIDStore(defaults: defaults).resolve()
        XCTAssertFalse(id.isEmpty)
        XCTAssertNotEqual(id, "anon", "the old collapsing literal must never be minted")
    }

    func testResolveIsStableWithinAStore() {
        let store = PatchDeviceIDStore(defaults: defaults)
        XCTAssertEqual(store.resolve(), store.resolve())
    }

    func testResolveIsStableAcrossRelaunch() {
        // A fresh store over the SAME defaults simulates the next app launch.
        let first = PatchDeviceIDStore(defaults: defaults).resolve()
        let second = PatchDeviceIDStore(defaults: defaults).resolve()
        XCTAssertEqual(first, second, "the id must survive relaunch or rollout buckets churn")
    }

    func testResolvePersistsUnderTheDocumentedKey() {
        let id = PatchDeviceIDStore(defaults: defaults).resolve()
        XCTAssertEqual(defaults.string(forKey: PatchDeviceIDStore.defaultsKey), id)
    }

    func testExistingStoredValueIsReusedNotOverwritten() {
        defaults.set("pre-existing-id", forKey: PatchDeviceIDStore.defaultsKey)
        XCTAssertEqual(PatchDeviceIDStore(defaults: defaults).resolve(), "pre-existing-id")
    }

    func testEmptyStoredValueIsReplaced() {
        defaults.set("", forKey: PatchDeviceIDStore.defaultsKey)
        let id = PatchDeviceIDStore(defaults: defaults).resolve()
        XCTAssertFalse(id.isEmpty, "an empty stored id would collapse the bucket like \"anon\"")
    }

    // MARK: - The bug this exists to prevent

    func testDistinctInstallsGetDistinctIDs() {
        // Each suite is a separate install. Identical ids here are exactly the
        // bug: every device would hash into one rollout bucket.
        var ids = Set<String>()
        var suites: [String] = []
        defer { suites.forEach { UserDefaults().removePersistentDomain(forName: $0) } }

        for _ in 0..<50 {
            let suite = "patchsdk.tests.deviceid.install.\(UUID().uuidString)"
            suites.append(suite)
            ids.insert(PatchDeviceIDStore(defaults: UserDefaults(suiteName: suite)!).resolve())
        }
        XCTAssertEqual(ids.count, 50, "distinct installs must report distinct device ids")
    }

    // MARK: - Configuration resolution

    func testExplicitDeviceIDWins() {
        let cfg = PatchConfiguration(appKey: "pak_test", deviceID: "my-own-id")
        XCTAssertEqual(cfg.resolvedDeviceID, "my-own-id")
    }

    func testNilDeviceIDFallsBackToThePersistedID() {
        let cfg = PatchConfiguration(appKey: "pak_test")
        let resolved = cfg.resolvedDeviceID
        XCTAssertFalse(resolved.isEmpty)
        XCTAssertNotEqual(resolved, "anon")
        XCTAssertEqual(resolved, cfg.resolvedDeviceID, "must be stable across reads")
    }

    func testEmptyDeviceIDIsTreatedAsUnset() {
        let cfg = PatchConfiguration(appKey: "pak_test", deviceID: "")
        XCTAssertFalse(cfg.resolvedDeviceID.isEmpty)
    }

    // MARK: - App groups (host app ⟷ extensions share one identity)

    func testAppGroupSuiteSharesOneIDAcrossTargets() {
        let group = "group.patchsdk.tests.\(UUID().uuidString)"
        defer {
            UserDefaults().removePersistentDomain(forName: group)
            PatchDeviceIDStore.resetRegistryForTesting()
        }
        // Two "targets" (host app + widget) resolving through the same group.
        let host = PatchDeviceIDStore.resolve(appGroupIdentifier: group)
        PatchDeviceIDStore.resetRegistryForTesting()   // simulate a separate process
        let widget = PatchDeviceIDStore.resolve(appGroupIdentifier: group)
        XCTAssertEqual(host, widget,
                       "an extension must not mint its own id — it double-counts devices and splits the rollout bucket")
    }

    /// Each group suite is read independently — a group that already holds an id
    /// keeps it rather than picking up another group's.
    ///
    /// Note this deliberately does NOT assert that two *fresh* groups mint
    /// different ids: `resolve(appGroupIdentifier:)` promotes an existing
    /// `.standard` id into a new group (see
    /// `testAdoptingAnAppGroupPreservesTheExistingStandardID`), so two fresh
    /// groups on one device legitimately converge on the same id. The device is
    /// the device; per-app scoping is the backend's job
    /// (`UniqueConstraint("app_id","device_id")`).
    func testEachAppGroupReadsItsOwnStoredID() {
        let g1 = "group.patchsdk.tests.\(UUID().uuidString)"
        let g2 = "group.patchsdk.tests.\(UUID().uuidString)"
        defer {
            [g1, g2].forEach { UserDefaults().removePersistentDomain(forName: $0) }
            PatchDeviceIDStore.resetRegistryForTesting()
        }
        UserDefaults(suiteName: g1)!.set("id-one", forKey: PatchDeviceIDStore.defaultsKey)
        UserDefaults(suiteName: g2)!.set("id-two", forKey: PatchDeviceIDStore.defaultsKey)

        XCTAssertEqual(PatchDeviceIDStore.resolve(appGroupIdentifier: g1), "id-one")
        XCTAssertEqual(PatchDeviceIDStore.resolve(appGroupIdentifier: g2), "id-two")
    }

    func testNilOrEmptyAppGroupFallsBackToStandard() {
        let a = PatchDeviceIDStore.resolve(appGroupIdentifier: nil)
        let b = PatchDeviceIDStore.resolve(appGroupIdentifier: "")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, PatchDeviceIDStore.shared.resolve())
    }

    func testAdoptingAnAppGroupPreservesTheExistingStandardID() {
        // An app that ships without a group, then adds one, must KEEP its id —
        // otherwise every existing install churns its rollout bucket and is
        // recounted as a new device against the plan cap.
        let existing = PatchDeviceIDStore.shared.resolve()
        let group = "group.patchsdk.tests.\(UUID().uuidString)"
        defer {
            UserDefaults().removePersistentDomain(forName: group)
            PatchDeviceIDStore.resetRegistryForTesting()
        }
        XCTAssertEqual(PatchDeviceIDStore.resolve(appGroupIdentifier: group), existing)
    }

    func testConfigurationRoutesThroughItsAppGroup() {
        let group = "group.patchsdk.tests.\(UUID().uuidString)"
        defer {
            UserDefaults().removePersistentDomain(forName: group)
            PatchDeviceIDStore.resetRegistryForTesting()
        }
        let cfg = PatchConfiguration(appKey: "pak_test", appGroupIdentifier: group)
        XCTAssertEqual(cfg.resolvedDeviceID,
                       PatchDeviceIDStore.resolve(appGroupIdentifier: group))
    }

    func testExplicitDeviceIDStillWinsOverAppGroup() {
        let cfg = PatchConfiguration(appKey: "pak_test", deviceID: "mine",
                                     appGroupIdentifier: "group.patchsdk.tests.ignored")
        XCTAssertEqual(cfg.resolvedDeviceID, "mine")
    }

    // MARK: - Concurrency

    /// `concurrentPerform`'s closure is `@Sendable`, so the accumulator has to be
    /// a reference type guarded by its own lock rather than a captured `var`.
    private final class SeenIDs: @unchecked Sendable {
        private let lock = NSLock()
        private var ids = Set<String>()
        func insert(_ id: String) { lock.lock(); ids.insert(id); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return ids.count }
    }

    func testConcurrentResolveMintsExactlyOneID() {
        let store = PatchDeviceIDStore(defaults: defaults)
        let seen = SeenIDs()

        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            seen.insert(store.resolve())
        }
        XCTAssertEqual(seen.count, 1, "a race must not mint competing ids")
    }
}
