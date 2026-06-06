import XCTest
@testable import PatchSDK

/// On-disk module cache: current/previous/bundled slots + atomic swap.
final class StorageTests: XCTestCase {

    private func tempStorage() throws -> (ModuleStorage, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("patch-storage-test-\(UUID().uuidString)")
        let s = try ModuleStorage(appKey: "test-app", baseDirectory: dir)
        return (s, dir)
    }

    override func tearDown() {
        super.tearDown()
    }

    func testInstallCurrentPersistsAndReadsBack() throws {
        let (s, dir) = try tempStorage()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bytes: [UInt8] = [1, 2, 3, 4, 5]
        try s.installCurrent(version: "1.0.0", sha256: "abc", bytes: bytes)
        XCTAssertEqual(s.currentVersion, "1.0.0")
        XCTAssertEqual(try s.currentBytes(), bytes)
        XCTAssertNil(s.previousVersion)
    }

    func testInstallDemotesCurrentToPrevious() throws {
        let (s, dir) = try tempStorage()
        defer { try? FileManager.default.removeItem(at: dir) }

        try s.installCurrent(version: "1.0.0", sha256: "v1", bytes: [1, 1, 1])
        try s.installCurrent(version: "1.1.0", sha256: "v2", bytes: [2, 2, 2])

        XCTAssertEqual(s.currentVersion, "1.1.0")
        XCTAssertEqual(s.previousVersion, "1.0.0")
        XCTAssertEqual(try s.currentBytes(), [2, 2, 2])
        XCTAssertEqual(try s.previousBytes(), [1, 1, 1])
    }

    func testManifestSurvivesReopen() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("patch-storage-reopen-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let s1 = try ModuleStorage(appKey: "app", baseDirectory: dir)
        try s1.installCurrent(version: "9.9.9", sha256: "sha", bytes: [7, 8, 9])

        // Reopen with a fresh instance pointed at the same dir.
        let s2 = try ModuleStorage(appKey: "app", baseDirectory: dir)
        XCTAssertEqual(s2.currentVersion, "9.9.9")
        XCTAssertEqual(try s2.currentBytes(), [7, 8, 9])
    }

    func testPromotePreviousToCurrent() throws {
        let (s, dir) = try tempStorage()
        defer { try? FileManager.default.removeItem(at: dir) }

        try s.installCurrent(version: "1.0.0", sha256: "v1", bytes: [1])
        try s.installCurrent(version: "2.0.0", sha256: "v2", bytes: [2])
        // Now current=2.0.0, previous=1.0.0. Promote previous (rollback).
        let promoted = try s.promotePreviousToCurrent()
        XCTAssertEqual(promoted, [1])
        XCTAssertEqual(s.currentVersion, "1.0.0")
        XCTAssertNil(s.previousVersion)
    }

    func testBundledSlot() throws {
        let (s, dir) = try tempStorage()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertFalse(s.hasBundled)
        s.registerBundled(version: "bundled-1.0", bytes: [9, 9, 9])
        XCTAssertTrue(s.hasBundled)
        XCTAssertEqual(s.bundledVersion(), "bundled-1.0")
        XCTAssertEqual(try s.bundledBytes(), [9, 9, 9])
    }

    func testClearAndReset() throws {
        let (s, dir) = try tempStorage()
        defer { try? FileManager.default.removeItem(at: dir) }

        try s.installCurrent(version: "1.0.0", sha256: "v1", bytes: [1])
        s.clearCurrent()
        XCTAssertNil(s.currentVersion)
        XCTAssertThrowsError(try s.currentBytes())

        try s.installCurrent(version: "2.0.0", sha256: "v2", bytes: [2])
        s.reset()
        XCTAssertNil(s.currentVersion)
        XCTAssertNil(s.previousVersion)
    }

    func testEmptySlotThrows() throws {
        let (s, dir) = try tempStorage()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertThrowsError(try s.currentBytes())
        XCTAssertThrowsError(try s.previousBytes())
        XCTAssertThrowsError(try s.promotePreviousToCurrent())
    }
}
