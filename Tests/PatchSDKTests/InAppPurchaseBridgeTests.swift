import XCTest
import WasmKit
@testable import PatchSDK

/// inAppPurchase (StoreKit) bridge tests.
///
/// The real StoreKit calls are iOS-only and injected as `@Sendable` closures, so
/// on macOS we (1) test the pure marshalling — `parseProductIDs` (id-array parse)
/// and `encodeProducts` (product-JSON encode) — directly as static helpers, and
/// (2) drive the registered host functions end-to-end through a tiny inline wasm
/// fixture (imports `patch.iap_products` / `patch.iap_purchase`, exports `call_*`
/// + `memory`/`patch_malloc`/`patch_free`) with injected spies, exercising the
/// full `(ptr,len)` + packed-i64 / i32 marshalling path against real guest memory.
/// Per the bridge guide, the prebuilt `BridgeFixture.wasm` does NOT export these
/// callers, so the suite carries its own fixture (compiled from WAT with
/// `wat2wasm`; bytes inlined so no external tool is needed at run time).
final class InAppPurchaseBridgeTests: XCTestCase {

    // MARK: - parseProductIDs (pure: JSON array of ids -> [String])

    func testParseProductIDsValid() {
        let json = Array(#"["com.app.pro","com.app.plus"]"#.utf8)
        XCTAssertEqual(InAppPurchaseBridge.parseProductIDs(json), ["com.app.pro", "com.app.plus"])
    }

    func testParseProductIDsSingle() {
        XCTAssertEqual(InAppPurchaseBridge.parseProductIDs(Array(#"["com.app.pro"]"#.utf8)),
                       ["com.app.pro"])
    }

    func testParseProductIDsEmptyArray() {
        XCTAssertEqual(InAppPurchaseBridge.parseProductIDs(Array("[]".utf8)), [])
    }

    /// Non-string elements (numbers, objects, null) are dropped; string siblings survive.
    func testParseProductIDsDropsNonStrings() {
        let json = Array(#"["a",123,{"k":"v"},null,"b"]"#.utf8)
        XCTAssertEqual(InAppPurchaseBridge.parseProductIDs(json), ["a", "b"])
    }

    /// A non-array payload (object / scalar / malformed) yields [].
    func testParseProductIDsNonArray() {
        XCTAssertEqual(InAppPurchaseBridge.parseProductIDs(Array(#"{"id":"x"}"#.utf8)), [])
        XCTAssertEqual(InAppPurchaseBridge.parseProductIDs(Array(#""just a string""#.utf8)), [])
        XCTAssertEqual(InAppPurchaseBridge.parseProductIDs(Array("not json [".utf8)), [])
    }

    // MARK: - encodeProducts (pure: [ProductInfo] -> JSON array bytes)

    func testEncodeProductsRoundTrips() throws {
        let products = [
            InAppPurchaseBridge.ProductInfo(id: "com.app.pro", price: "$4.99", displayName: "Pro"),
            InAppPurchaseBridge.ProductInfo(id: "com.app.plus", price: "$9.99", displayName: "Plus"),
        ]
        let bytes = try XCTUnwrap(InAppPurchaseBridge.encodeProducts(products))

        let arr = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(bytes)) as? [[String: Any]]
        )
        XCTAssertEqual(arr.count, 2, "order + count preserved")
        XCTAssertEqual(arr[0]["id"] as? String, "com.app.pro")
        XCTAssertEqual(arr[0]["price"] as? String, "$4.99")
        XCTAssertEqual(arr[0]["displayName"] as? String, "Pro")
        XCTAssertEqual(arr[1]["id"] as? String, "com.app.plus")
        XCTAssertEqual(arr[1]["price"] as? String, "$9.99")
        XCTAssertEqual(arr[1]["displayName"] as? String, "Plus")
    }

    /// With sorted keys, a single product encodes to an exact, stable JSON string.
    func testEncodeProductsExactJSON() throws {
        let bytes = try XCTUnwrap(InAppPurchaseBridge.encodeProducts([
            InAppPurchaseBridge.ProductInfo(id: "com.app.pro", price: "$4.99", displayName: "Pro")
        ]))
        XCTAssertEqual(
            String(decoding: bytes, as: UTF8.self),
            #"[{"displayName":"Pro","id":"com.app.pro","price":"$4.99"}]"#
        )
    }

    /// An empty product list encodes to nil → the host returns packed 0 ("no value").
    func testEncodeProductsEmptyIsNil() {
        XCTAssertNil(InAppPurchaseBridge.encodeProducts([]))
    }

    /// JSON-significant characters in product fields are escaped (still valid JSON).
    func testEncodeProductsEscapesSpecialCharacters() throws {
        let tricky = InAppPurchaseBridge.ProductInfo(
            id: "com.app.\"x\"", price: "1\t2", displayName: "A \\ B")
        let bytes = try XCTUnwrap(InAppPurchaseBridge.encodeProducts([tricky]))
        let arr = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(bytes)) as? [[String: Any]]
        )
        XCTAssertEqual(arr[0]["id"] as? String, "com.app.\"x\"")
        XCTAssertEqual(arr[0]["price"] as? String, "1\t2")
        XCTAssertEqual(arr[0]["displayName"] as? String, "A \\ B")
    }

    // MARK: - Inline wasm fixture (full guest -> host marshalling)

    /// `iap_fixture.wasm` bytes (wat2wasm 1.0.x). Imports `patch.iap_products` /
    /// `patch.iap_purchase`, exports `call_iap_products` / `call_iap_purchase`
    /// plus `memory` / `patch_malloc` (8-byte-aligned bump allocator) / `patch_free`.
    private static let fixtureBytes: [UInt8] = [
        0, 97, 115, 109, 1, 0, 0, 0, 1, 22, 4, 96, 2, 127, 127, 1,
        126, 96, 2, 127, 127, 1, 127, 96, 1, 127, 1, 127, 96, 1, 127, 0,
        2, 43, 2, 5, 112, 97, 116, 99, 104, 12, 105, 97, 112, 95, 112, 114,
        111, 100, 117, 99, 116, 115, 0, 0, 5, 112, 97, 116, 99, 104, 12, 105,
        97, 112, 95, 112, 117, 114, 99, 104, 97, 115, 101, 0, 1, 3, 5, 4,
        2, 3, 0, 1, 5, 3, 1, 0, 2, 6, 7, 1, 127, 1, 65, 128,
        8, 11, 7, 78, 5, 6, 109, 101, 109, 111, 114, 121, 2, 0, 12, 112,
        97, 116, 99, 104, 95, 109, 97, 108, 108, 111, 99, 0, 2, 10, 112, 97,
        116, 99, 104, 95, 102, 114, 101, 101, 0, 3, 17, 99, 97, 108, 108, 95,
        105, 97, 112, 95, 112, 114, 111, 100, 117, 99, 116, 115, 0, 4, 17, 99,
        97, 108, 108, 95, 105, 97, 112, 95, 112, 117, 114, 99, 104, 97, 115, 101,
        0, 5, 10, 46, 4, 23, 1, 1, 127, 35, 0, 33, 1, 35, 0, 32,
        0, 106, 65, 7, 106, 65, 120, 113, 36, 0, 32, 1, 11, 2, 0, 11,
        8, 0, 32, 0, 32, 1, 16, 0, 11, 8, 0, 32, 0, 32, 1, 16,
        1, 11,
    ]

    /// Thread-safe spy recording the ids/product-ids the bridge dispatches.
    private final class Spy: @unchecked Sendable {
        private let lock = NSLock()
        private var _requestedIDs: [[String]] = []
        private var _purchasedIDs: [String] = []
        let productsToReturn: [InAppPurchaseBridge.ProductInfo]
        let purchaseResult: Bool

        init(productsToReturn: [InAppPurchaseBridge.ProductInfo] = [], purchaseResult: Bool = true) {
            self.productsToReturn = productsToReturn
            self.purchaseResult = purchaseResult
        }

        func recordProducts(_ ids: [String]) -> [InAppPurchaseBridge.ProductInfo] {
            lock.lock(); _requestedIDs.append(ids); lock.unlock()
            return productsToReturn
        }
        func recordPurchase(_ id: String) -> Bool {
            lock.lock(); _purchasedIDs.append(id); lock.unlock()
            return purchaseResult
        }
        var requestedIDs: [[String]] { lock.lock(); defer { lock.unlock() }; return _requestedIDs }
        var purchasedIDs: [String] { lock.lock(); defer { lock.unlock() }; return _purchasedIDs }
    }

    private func makeRuntime(_ spy: Spy) throws -> WASMRuntime {
        let registry = BridgeRegistry()
        registry.register(InAppPurchaseBridge(
            products: { spy.recordProducts($0) },
            purchase: { spy.recordPurchase($0) }
        ))
        return try WASMRuntime(bytes: Self.fixtureBytes, hostImports: registry.hostImports())
    }

    private func readPacked(_ packed: UInt64, from rt: WASMRuntime) throws -> [UInt8] {
        if packed == 0 { return [] }
        return try rt.read(ptr: UInt32(packed >> 32), len: UInt32(packed & 0xffff_ffff))
    }

    /// iap_products: the guest's JSON id array is parsed and handed to the injected
    /// fetcher; the returned products encode back to the guest as packed JSON.
    func testProductsRoundTripThroughBridge() throws {
        let spy = Spy(productsToReturn: [
            InAppPurchaseBridge.ProductInfo(id: "com.app.pro", price: "$4.99", displayName: "Pro"),
        ])
        let rt = try makeRuntime(spy)

        let (p, l) = try rt.writeBuffer(Array(#"["com.app.pro","com.app.plus"]"#.utf8))
        let res = try rt.invoke("call_iap_products", [.i32(p), .i32(l)])

        // The injected fetcher saw exactly the parsed ids.
        XCTAssertEqual(spy.requestedIDs, [["com.app.pro", "com.app.plus"]])

        // The guest receives the encoded product JSON.
        let bytes = try readPacked(res[0].i64, from: rt)
        let arr = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(bytes)) as? [[String: Any]]
        )
        XCTAssertEqual(arr.count, 1)
        XCTAssertEqual(arr[0]["id"] as? String, "com.app.pro")
        XCTAssertEqual(arr[0]["price"] as? String, "$4.99")
        XCTAssertEqual(arr[0]["displayName"] as? String, "Pro")
    }

    /// No matching products → the fetcher returns [] → the host returns packed 0.
    func testProductsEmptyReturnsZero() throws {
        let spy = Spy(productsToReturn: [])
        let rt = try makeRuntime(spy)

        let (p, l) = try rt.writeBuffer(Array(#"["com.app.unknown"]"#.utf8))
        let res = try rt.invoke("call_iap_products", [.i32(p), .i32(l)])
        XCTAssertEqual(res[0].i64, 0, "no products -> packed 0 (nil)")
        XCTAssertEqual(spy.requestedIDs, [["com.app.unknown"]])
    }

    /// iap_purchase: the guest's product-id string reaches the injected purchaser;
    /// a successful purchase returns i32 1.
    func testPurchaseSuccessReturnsOne() throws {
        let spy = Spy(purchaseResult: true)
        let rt = try makeRuntime(spy)

        let (p, l) = try rt.writeBuffer(Array("com.app.pro".utf8))
        let res = try rt.invoke("call_iap_purchase", [.i32(p), .i32(l)])
        XCTAssertEqual(res[0].i32, 1, "successful purchase -> 1")
        XCTAssertEqual(spy.purchasedIDs, ["com.app.pro"])
    }

    /// A failed / cancelled purchase returns i32 0.
    func testPurchaseFailureReturnsZero() throws {
        let spy = Spy(purchaseResult: false)
        let rt = try makeRuntime(spy)

        let (p, l) = try rt.writeBuffer(Array("com.app.pro".utf8))
        let res = try rt.invoke("call_iap_purchase", [.i32(p), .i32(l)])
        XCTAssertEqual(res[0].i32, 0, "failed/cancelled purchase -> 0")
        XCTAssertEqual(spy.purchasedIDs, ["com.app.pro"])
    }

    // MARK: - Registration wiring

    func testBridgeModuleNamespace() {
        let bridge = InAppPurchaseBridge(products: { _ in [] }, purchase: { _ in false })
        XCTAssertEqual(bridge.module, "patch")
    }

    func testBridgeRegistersWithoutError() throws {
        let registry = BridgeRegistry()
        registry.register(InAppPurchaseBridge(products: { _ in [] }, purchase: { _ in false }))
        XCTAssertNotNil(registry.hostImports())
        XCTAssertNoThrow(try WASMRuntime(bytes: Self.fixtureBytes,
                                         hostImports: registry.hostImports()))
    }
}
