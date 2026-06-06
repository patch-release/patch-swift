import XCTest
import WasmKit
@testable import PatchSDK

/// Round-trips each marshalled type through the WASMBridgeable layer, using a
/// real guest allocator (MarshalFixture) for the linear-memory types so the
/// (ptr,len) ABI is exercised end to end — not just in-process.
final class MarshallingTests: XCTestCase {

    private func makeRuntime() throws -> WASMRuntime {
        guard let url = Bundle.module.url(forResource: "MarshalFixture.release", withExtension: "wasm") else {
            throw PatchRuntimeError.memoryMissing
        }
        return try WASMRuntime(bytes: [UInt8](try Data(contentsOf: url)))
    }

    // Helper: lower a value, then raise it back from the same Value words.
    private func roundTrip<T: WASMBridgeable & Equatable>(_ value: T, ctx: MarshalContext) throws -> T {
        let lowered = try value.lower(into: ctx)
        var idx = 0
        return try T.raise(from: lowered, index: &idx, ctx: ctx)
    }

    func testScalarRoundTrips() throws {
        let ctx = MarshalContext(runtime: try makeRuntime())
        defer { ctx.release() }

        XCTAssertEqual(try roundTrip(true, ctx: ctx), true)
        XCTAssertEqual(try roundTrip(false, ctx: ctx), false)
        XCTAssertEqual(try roundTrip(Int32(-2_000_000), ctx: ctx), -2_000_000)
        XCTAssertEqual(try roundTrip(Int64(9_000_000_000), ctx: ctx), 9_000_000_000)
        XCTAssertEqual(try roundTrip(Int(-42), ctx: ctx), -42)
        XCTAssertEqual(try roundTrip(Double.pi, ctx: ctx), Double.pi)
    }

    func testStringRoundTripThroughGuestMemory() throws {
        let ctx = MarshalContext(runtime: try makeRuntime())
        defer { ctx.release() }
        let s = "Patch — naïve façade 日本語"
        XCTAssertEqual(try roundTrip(s, ctx: ctx), s)
    }

    func testDataRoundTripThroughGuestMemory() throws {
        let ctx = MarshalContext(runtime: try makeRuntime())
        defer { ctx.release() }
        let d = Data((0..<200).map { UInt8($0 % 256) })
        XCTAssertEqual(try roundTrip(d, ctx: ctx), d)
        XCTAssertEqual(try roundTrip(Data(), ctx: ctx), Data())   // empty
    }

    func testOptionalRoundTrip() throws {
        let ctx = MarshalContext(runtime: try makeRuntime())
        defer { ctx.release() }

        let present: Int32? = 7
        let absent: Int32? = nil
        XCTAssertEqual(try roundTrip(present, ctx: ctx), 7)
        XCTAssertEqual(try roundTrip(absent, ctx: ctx), nil)

        // Optional String (linear-memory payload) too.
        let someStr: String? = "hi"
        let noneStr: String? = nil
        XCTAssertEqual(try roundTrip(someStr, ctx: ctx), "hi")
        XCTAssertEqual(try roundTrip(noneStr, ctx: ctx), nil)
    }

    // A representative business-logic Codable struct.
    struct CartItem: Codable, Equatable {
        let sku: String
        let qty: Int
        let priceCents: Int
    }
    struct Cart: Codable, Equatable {
        let items: [CartItem]
        var totalCents: Int
        let coupon: String?
        let appliedAt: Double   // unix seconds (Date-like, no Foundation Date dep)
    }

    func testCodableViaMessagePackRoundTrip() throws {
        let ctx = MarshalContext(runtime: try makeRuntime())
        defer { ctx.release() }

        let cart = Cart(
            items: [
                CartItem(sku: "A", qty: 2, priceCents: 150),
                CartItem(sku: "B", qty: 1, priceCents: 99)
            ],
            totalCents: 399,
            coupon: "SAVE10",
            appliedAt: 1_700_000_000.5
        )

        let bridge = MessagePackBridge(cart)
        let lowered = try bridge.lower(into: ctx)
        XCTAssertEqual(lowered.count, 2, "Codable marshals as (ptr,len)")

        var idx = 0
        let raised = try MessagePackBridge<Cart>.raise(from: lowered, index: &idx, ctx: ctx)
        XCTAssertEqual(raised.value, cart)
    }

    func testMessagePackDirectRoundTrips() throws {
        // Pure codec round-trips — no WASM involved.
        struct Mixed: Codable, Equatable {
            let i: Int; let u: UInt64; let d: Double; let b: Bool
            let s: String; let bin: Data; let opt: Int?; let arr: [String]
            let map: [String: Int]
        }
        let m = Mixed(i: -5, u: .max, d: -0.125, b: true, s: "ok",
                      bin: Data([0xDE, 0xAD]), opt: nil, arr: ["x", "y"],
                      map: ["a": 1])
        let bytes = try MessagePack.encode(m)
        XCTAssertEqual(try MessagePack.decode(Mixed.self, from: bytes), m)

        // Top-level array and scalar.
        let nums = [1, 2, 3, -4]
        XCTAssertEqual(try MessagePack.decode([Int].self, from: MessagePack.encode(nums)), nums)
        XCTAssertEqual(try MessagePack.decode(String.self, from: MessagePack.encode("hi")), "hi")
    }

    /// MessagePack blob written into real guest memory and read back, mirroring
    /// how a guest reading a Codable arg would see it.
    func testMessagePackBlobThroughGuestMemory() throws {
        let runtime = try makeRuntime()
        let item = CartItem(sku: "Z", qty: 9, priceCents: 1234)
        let (ptr, len) = try MessagePack.writeBlob(item, into: runtime)
        defer { runtime.free(ptr) }
        // sum_bytes proves the bytes are really in guest memory (non-empty).
        let sum = try runtime.invoke("sum_bytes", [.i32(ptr), .i32(len)])[0].i32
        XCTAssertGreaterThan(sum, 0)
        let back: CartItem = try MessagePack.readBlob(CartItem.self, ptr: ptr, len: len, from: runtime)
        XCTAssertEqual(back, item)
    }
}
