import XCTest
@testable import PatchSDK

/// Hardening tests for the hand-rolled MessagePack reader against malformed /
/// hostile input (a WASM guest module's result blob is untrusted).
///
/// Regression: an array32/map32 header carries a 32-bit element count (up to
/// ~4.29 billion). The reader used to call `reserveCapacity(n)` with that count
/// BEFORE reading any elements, so a 5-byte blob `dd ff ff ff ff` requested a
/// ~4.29B-element allocation (tens of GB) → OOM crash on the host. The reader
/// must reject a count that exceeds the bytes remaining (each element needs at
/// least one byte) instead of attempting the allocation.
final class MessagePackHardeningTests: XCTestCase {

    /// array32 claiming ~4.29B elements with no payload → throws, never OOMs.
    func testHugeArrayCountIsRejectedNotAllocated() {
        let blob: [UInt8] = [0xdd, 0xff, 0xff, 0xff, 0xff]  // array32, count = 0xffffffff
        XCTAssertThrowsError(try MessagePack.decode([Int].self, from: blob)) { error in
            XCTAssertTrue(error is MessagePackError, "expected MessagePackError, got \(error)")
        }
    }

    /// map32 claiming ~4.29B entries with no payload → throws, never OOMs.
    func testHugeMapCountIsRejectedNotAllocated() {
        let blob: [UInt8] = [0xdf, 0xff, 0xff, 0xff, 0xff]  // map32, count = 0xffffffff
        XCTAssertThrowsError(try MessagePack.decode([String: Int].self, from: blob)) { error in
            XCTAssertTrue(error is MessagePackError, "expected MessagePackError, got \(error)")
        }
    }

    /// array16 claiming more elements than the bytes can hold → throws.
    func testArray16OverrunIsRejected() {
        // array16, count = 0x00ff (255), but only one following byte.
        let blob: [UInt8] = [0xdc, 0x00, 0xff, 0x01]
        XCTAssertThrowsError(try MessagePack.decode([Int].self, from: blob)) { error in
            XCTAssertTrue(error is MessagePackError)
        }
    }

    /// A genuine, correctly-sized array still round-trips (no false rejection).
    func testWellFormedArrayStillDecodes() throws {
        let nums = [1, 2, 3, 4, 5]
        let bytes = try MessagePack.encode(nums)
        XCTAssertEqual(try MessagePack.decode([Int].self, from: bytes), nums)
    }

    /// A genuine, correctly-sized map still round-trips.
    func testWellFormedMapStillDecodes() throws {
        let m = ["a": 1, "b": 2]
        let bytes = try MessagePack.encode(m)
        XCTAssertEqual(try MessagePack.decode([String: Int].self, from: bytes), m)
    }
}
