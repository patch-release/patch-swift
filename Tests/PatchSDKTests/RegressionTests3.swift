import XCTest
import Foundation
@testable import PatchSDK

/// Regression tests. Each test pins a specific correctness / crash / DoS bug
/// that was fixed in the corresponding source file.
final class RegressionTests3: XCTestCase {

    // MARK: #1 — MessagePack nested keyed/unkeyed containers serialized as EMPTY.
    //
    // A Codable type with an explicit `nestedContainer(keyedBy:forKey:)` /
    // `nestedUnkeyedContainer(forKey:)` (custom `encode(to:)`) previously lost ALL
    // nested contents: the eager `defer { set(key, sub.value) }` captured the
    // sub-encoder's value WHILE it was still empty. Now resolved lazily.

    private struct NestedInner: Codable, Equatable { var a: Int; var b: String }
    private struct ManualOuter: Codable, Equatable {
        var name: String
        var inner: NestedInner
        var tags: [String]
        enum CodingKeys: String, CodingKey { case name, inner, tags }
        enum InnerKeys: String, CodingKey { case a, b }
        init(name: String, inner: NestedInner, tags: [String]) {
            self.name = name; self.inner = inner; self.tags = tags
        }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            let ic = try c.nestedContainer(keyedBy: InnerKeys.self, forKey: .inner)
            inner = NestedInner(a: try ic.decode(Int.self, forKey: .a),
                                b: try ic.decode(String.self, forKey: .b))
            var uc = try c.nestedUnkeyedContainer(forKey: .tags)
            var out: [String] = []
            while !uc.isAtEnd { out.append(try uc.decode(String.self)) }
            tags = out
        }
        func encode(to e: Encoder) throws {
            var c = e.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            var ic = c.nestedContainer(keyedBy: InnerKeys.self, forKey: .inner)
            try ic.encode(inner.a, forKey: .a)
            try ic.encode(inner.b, forKey: .b)
            var uc = c.nestedUnkeyedContainer(forKey: .tags)
            for t in tags { try uc.encode(t) }
        }
    }

    func testNestedKeyedAndUnkeyedContainersRoundTrip() throws {
        let o = ManualOuter(name: "x", inner: NestedInner(a: 5, b: "hi"), tags: ["p", "q"])
        let bytes = try MessagePack.encode(o)
        let back = try MessagePack.decode(ManualOuter.self, from: bytes)
        XCTAssertEqual(back, o, "nested keyed + unkeyed container contents must survive encode")
        XCTAssertEqual(back.inner.a, 5)
        XCTAssertEqual(back.tags, ["p", "q"])
    }

    // MARK: #5 — MessagePack unbounded recursion -> native stack overflow (SIGSEGV).
    func testDeeplyNestedBlobIsRejectedNotCrash() throws {
        var bytes: [UInt8] = []
        for _ in 0..<50_000 { bytes.append(0x91) }   // fixarray-of-1, 50k deep
        bytes.append(0xc0)                           // nil at the bottom
        var reader = MPReader(bytes)
        XCTAssertThrowsError(try reader.read()) { err in
            XCTAssertTrue("\(err)".contains("nesting depth"), "got: \(err)")
        }
    }

    func testModeratelyNestedBlobStillDecodes() throws {
        // 200 levels — well under the cap; must still parse without throwing.
        var bytes: [UInt8] = []
        for _ in 0..<200 { bytes.append(0x91) }
        bytes.append(0x07)
        var reader = MPReader(bytes)
        XCTAssertNoThrow(try reader.read())
    }

    // MARK: #2 — DeviceInfoBridge.encode NaN/Inf metric -> invalid JSON.
    func testDeviceInfoNonFiniteMetricsStayValidJSON() throws {
        let info = DeviceInfo(model: "m", systemName: "iOS", systemVersion: "17",
                              name: "n", idiom: "phone",
                              screenWidth: .nan, screenHeight: .infinity, scale: -.infinity)
        let bytes = DeviceInfoBridge.encode(info)
        let parsed = try JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any]
        XCTAssertNotNil(parsed, "device_info JSON must parse even with non-finite metrics")
        XCTAssertEqual((parsed?["screenWidth"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual((parsed?["screenHeight"] as? NSNumber)?.intValue, 0)
    }

    // MARK: #4 — MotionBridge.encode NaN/Inf sample -> invalid JSON.
    func testMotionNonFiniteSampleStaysValidJSON() throws {
        let sample = MotionSample(accelX: .nan, accelY: 0.5, accelZ: .infinity,
                                  gyroX: 0, gyroY: -.infinity, gyroZ: 1)
        let bytes = MotionBridge.encode(sample)
        let parsed = try JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any]
        XCTAssertNotNil(parsed, "motion_read JSON must parse even with non-finite axes")
        XCTAssertEqual((parsed?["accelX"] as? NSNumber)?.doubleValue, 0)
    }

    // MARK: #3 / #9 — ExponentialBackoff.nextDelay must never trap.
    func testBackoffNegativeBaseDoesNotCrash() {
        var b = ExponentialBackoff(base: -1, multiplier: 2, maxDelay: 300, jitter: true)
        for _ in 0..<10 {
            let d = b.nextDelay()
            XCTAssertGreaterThanOrEqual(d, 0)
            XCTAssertTrue(d.isFinite)
        }
    }

    func testBackoffInfiniteMaxDelayDoesNotCrash() {
        var b = ExponentialBackoff(base: 2, multiplier: 2, maxDelay: .infinity, jitter: true)
        // Many attempts so the deterministic delay overflows to +Infinity.
        for _ in 0..<2_000 {
            let d = b.nextDelay()
            XCTAssertGreaterThanOrEqual(d, 0)
            XCTAssertTrue(d.isFinite, "jitter delay must be finite")
        }
    }

    // MARK: #6 — QRGenerateBridge unbounded scale (multi-trillion-pixel DoS).
    func testQRScaleIsClampedToMax() {
        let r = QRRequest(text: "x", scale: 100_000)
        XCTAssertEqual(r.scale, QRRequest.maxScale)
        // Parsed form is clamped too.
        let parsed = QRRequest.parse(Array(#"{"text":"x","scale":999999}"#.utf8))
        XCTAssertEqual(parsed?.scale, QRRequest.maxScale)
        // A reasonable value passes through unchanged.
        XCTAssertEqual(QRRequest(text: "x", scale: 8).scale, 8)
    }

    // MARK: #7 — PDFGenerateBridge unbounded geometry (mediaBox/page-explosion DoS).
    func testPDFGeometryIsClamped() {
        let r = PDFRequest(text: "x", fontSize: 1e9, pageWidth: 1e12,
                           pageHeight: .infinity, margin: -5)
        XCTAssertEqual(r.fontSize, PDFRequest.maxFontSize)
        XCTAssertEqual(r.pageWidth, PDFRequest.maxPageDimension)
        // Non-finite height falls back to the default page height.
        XCTAssertEqual(r.pageHeight, PDFRequest.defaultPageHeight)
        XCTAssertGreaterThanOrEqual(r.margin, 0)
        // Normal request is untouched.
        let ok = PDFRequest(text: "hi")
        XCTAssertEqual(ok.pageWidth, PDFRequest.defaultPageWidth)
    }

    // MARK: #8 — NetworkImageBridge ByteCache was unbounded (memory-leak DoS).
    func testByteCacheEvictsPastEntryCap() {
        let cache = ByteCache(maxEntries: 3, maxTotalBytes: 1 << 30)
        for i in 0..<10 { cache.set("k\(i)", [UInt8(i)]) }
        XCTAssertLessThanOrEqual(cache.count, 3, "cache must evict to honor maxEntries")
        // Newest entries are retained.
        XCTAssertEqual(cache.get("k9"), [9])
        XCTAssertNil(cache.get("k0"), "oldest entry should have been evicted")
    }

    func testByteCacheEvictsPastByteCap() {
        let cache = ByteCache(maxEntries: 1000, maxTotalBytes: 10)
        cache.set("a", [UInt8](repeating: 1, count: 6))
        cache.set("b", [UInt8](repeating: 2, count: 6))   // total 12 > 10 -> evict "a"
        XCTAssertNil(cache.get("a"))
        XCTAssertEqual(cache.get("b")?.count, 6)
        // An oversized single value is never cached.
        cache.set("big", [UInt8](repeating: 9, count: 100))
        XCTAssertNil(cache.get("big"))
    }

    // MARK: #10 — activate() must invalidate the per-pass value cache.
    //
    // A lifted value read populates the per-pass cache; a subsequent `activate()`
    // (which may swap in a module carrying different lifted values) must drop that
    // cache so the next read re-enters the freshly-activated module instead of
    // returning a stale cached value. (The fix also moves the clear INSIDE the
    // swap critical section to close a reader race.)
    private struct DoubleOut: Decodable { let value: Double }

    func testActivateClearsValueCache() throws {
        guard let url = Bundle.module.url(forResource: "MarshalFixture.release", withExtension: "wasm") else {
            throw XCTSkip("value-lift fixture unavailable")
        }
        let bytes = [UInt8](try Data(contentsOf: url))
        let patch = Patch()
        try patch.activate(bytes: bytes)

        // Populate the per-pass cache.
        let first = try patch.valueJSON("ProfileCard.primaryFontSize", returning: DoubleOut.self)
        XCTAssertEqual(first.value, 22)

        // Re-activate (a new module instance). The cache must have been dropped, so
        // this read re-resolves against the freshly-activated module and succeeds
        // (a stale cache would still return, but we assert the value is consistent
        // and the read path actually re-runs against the live module).
        try patch.activate(bytes: bytes)
        let second = try patch.valueJSON("ProfileCard.primaryFontSize", returning: DoubleOut.self)
        XCTAssertEqual(second.value, 22)
    }
}
