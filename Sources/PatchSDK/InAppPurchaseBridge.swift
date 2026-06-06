import Foundation
import WasmKit
// NOTE: StoreKit is imported ONLY on real device platforms (iOS / tvOS /
// visionOS). We deliberately do NOT use `#if canImport(StoreKit)` and do NOT
// import StoreKit on macOS: on macOS, importing StoreKit transitively re-exports
// SwiftUI, whose `extension Optional: Gesture` then collides with this module's
// `extension Optional: WASMBridgeable` (Marshalling.swift) during whole-module
// type-checking — that collision broke the whole-module build for a prior bridge.
// The macOS host build is the test build, and tests inject the StoreKit
// capability as closures (guide Rule 2), so the real StoreKit path is never
// compiled there. On the iOS family the convenience `init()` wires the real
// StoreKit 2 product fetch + purchase.
#if os(iOS) || os(tvOS) || os(visionOS)
import StoreKit
#endif

// MARK: - inAppPurchase (StoreKit) bridge
//
// Lets an OTA patch read a product catalog and run a purchase through the host
// app's real StoreKit. Mirrors `URLSessionBridge`'s sync-over-async shape: the
// guest call is synchronous, the host blocks on a `DispatchSemaphore` while the
// async StoreKit work completes, then returns the result.
//
// ## Host functions (module "patch")
//   * iap_products(ptr,len) -> packed i64 (ptr<<32|len)
//       arg  = JSON array of product ids, e.g. `["com.app.pro","com.app.plus"]`
//       ret  = packed JSON array of product info:
//              `[{"id":"com.app.pro","price":"$4.99","displayName":"Pro"}]`
//              (0 = no products / parse failure).
//   * iap_purchase(ptr,len) -> i32  (1 = purchased, 0 = failed / cancelled)
//       arg  = product id string. Runs SYNCHRONOUSLY from the guest's view
//              (blocks on a semaphore like `URLSessionBridge.syncGet`).
//
// ## Cross-platform core + injected dependency (guide Rule 2)
// The bridge stores two `@Sendable` closures so the whole struct + its
// `register(...)` marshalling compiles on macOS (where the StoreKit import is
// intentionally absent — see the import note above):
//   * `products: @Sendable ([String]) -> [ProductInfo]`
//   * `purchase: @Sendable (String) -> Bool`
// Tests inject spies and assert the id-array parse + product-JSON encode (both
// pulled into `static func` helpers and tested directly). The convenience
// `init()` (device platforms only) wires the real StoreKit 2 calls.
public struct InAppPurchaseBridge: Bridge {
    /// Minimal product description handed back to the guest. Cross-platform
    /// value type (no StoreKit dependency) so it compiles on macOS; the device
    /// `init()` maps real `StoreKit.Product`s into this.
    public struct ProductInfo: Sendable, Equatable {
        public let id: String
        public let price: String
        public let displayName: String
        public init(id: String, price: String, displayName: String) {
            self.id = id
            self.price = price
            self.displayName = displayName
        }
    }

    /// Fetch product info for the given ids. Injected so the bridge is testable
    /// on macOS; the convenience init supplies the real StoreKit fetch.
    public typealias FetchProducts = @Sendable (_ ids: [String]) -> [ProductInfo]
    /// Run a purchase for the given product id. Returns true on a successful
    /// purchase, false on failure / cancellation. Injected (see above).
    public typealias Purchase = @Sendable (_ productID: String) -> Bool

    public let module = "patch"
    private let products: FetchProducts
    private let purchase: Purchase

    /// Cross-platform designated init — tests inject spies here.
    public init(products: @escaping FetchProducts, purchase: @escaping Purchase) {
        self.products = products
        self.purchase = purchase
    }

    #if os(iOS) || os(tvOS) || os(visionOS)
    /// Convenience default init: wire the real StoreKit 2 catalog + purchase.
    /// Both calls are sync-over-async (block on a semaphore) so the bridge's
    /// host functions stay synchronous from the guest's perspective, exactly
    /// like `URLSessionBridge.syncGet`.
    public init() {
        self.init(
            products: { ids in Self.fetchProductsNative(ids) },
            purchase: { id in Self.purchaseNative(id) }
        )
    }

    /// Real StoreKit 2 product fetch, blocking until the async query completes.
    private static func fetchProductsNative(_ ids: [String]) -> [ProductInfo] {
        let sem = DispatchSemaphore(value: 0)
        let box = ResultBox<[ProductInfo]>()
        Task {
            defer { sem.signal() }
            guard let storeProducts = try? await Product.products(for: ids) else {
                box.set([])
                return
            }
            box.set(storeProducts.map {
                ProductInfo(id: $0.id, price: $0.displayPrice, displayName: $0.displayName)
            })
        }
        _ = sem.wait(timeout: .now() + 30)
        return box.get() ?? []
    }

    /// Real StoreKit 2 purchase, blocking until the async flow resolves.
    /// Returns true only for `.success` with a verified transaction (which is
    /// then finished); `.userCancelled` / `.pending` / errors → false.
    private static func purchaseNative(_ productID: String) -> Bool {
        let sem = DispatchSemaphore(value: 0)
        let box = ResultBox<Bool>()
        Task {
            defer { sem.signal() }
            guard let product = try? await Product.products(for: [productID]).first else {
                box.set(false)
                return
            }
            guard let result = try? await product.purchase() else {
                box.set(false)
                return
            }
            switch result {
            case .success(let verification):
                if case .verified(let transaction) = verification {
                    await transaction.finish()
                    box.set(true)
                } else {
                    box.set(false)
                }
            case .userCancelled, .pending:
                box.set(false)
            @unknown default:
                box.set(false)
            }
        }
        _ = sem.wait(timeout: .now() + 60)
        return box.get() ?? false
    }
    #endif

    // MARK: - Pure marshalling (static, unit-tested directly)

    /// Parse the `iap_products` arg — a JSON array of product id strings — into
    /// `[String]`. Non-string elements are dropped; a non-array / malformed
    /// payload yields `[]`. Exposed as a `static func` (mirroring
    /// `AnalyticsBridge.parseTrack`) so the parsing is unit-tested without a
    /// wasm instance; the registered host function calls exactly this.
    public static func parseProductIDs(_ bytes: [UInt8]) -> [String] {
        guard let arr = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [Any] else {
            return []
        }
        return arr.compactMap { $0 as? String }
    }

    /// Encode product info into the `iap_products` result — a JSON array of
    /// `{"id","price","displayName"}` objects, in the order given. Returns nil
    /// for an empty list (→ packed 0 "no value"). Exposed as a `static func` so
    /// the encoding is unit-tested directly; the registered host function calls
    /// exactly this.
    public static func encodeProducts(_ products: [ProductInfo]) -> [UInt8]? {
        guard !products.isEmpty else { return nil }
        let objects: [[String: String]] = products.map {
            ["id": $0.id, "price": $0.price, "displayName": $0.displayName]
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: objects, options: [.sortedKeys]
        ) else { return nil }
        return [UInt8](data)
    }

    public func register(into imports: inout Imports, store: Store) {
        let products = self.products
        let purchase = self.purchase

        // iap_products(ptr,len) -> packed i64 JSON array.
        imports.host(module, "iap_products", [.i32, .i32], [.i64], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let bytes = try ctx.readBytes(ptr: args[0].i32, len: args[1].i32)
            let ids = Self.parseProductIDs(bytes)
            let info = products(ids)
            return [try ctx.packedResult(Self.encodeProducts(info))]
        }

        // iap_purchase(ptr,len) -> i32 (1 success / 0 fail/cancel). Synchronous
        // from the guest's view; the injected closure blocks (semaphore) when
        // wired to real StoreKit.
        imports.host(module, "iap_purchase", [.i32, .i32], [.i32], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let productID = try ctx.readString(ptr: args[0].i32, len: args[1].i32)
            return [.i32(purchase(productID) ? 1 : 0)]
        }
    }
}

/// Tiny thread-safe box so an async/completion handler can hand a value back to
/// the blocking (semaphore-waiting) caller without a data-race warning. Mirrors
/// `ByteBox` in Bridges.swift, generalized to any `Sendable` payload.
private final class ResultBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func get() -> T? { lock.lock(); defer { lock.unlock() }; return value }
}
