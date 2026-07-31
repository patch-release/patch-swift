// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Embedded Swift source fixtures for the unit tests.
enum Fixtures {
    static let fixtureURL = URL(fileURLWithPath: "/tmp/PatchFixtures/Sample.swift")

    /// A small mixed sample: pure math, a native networking call, a UserDefaults
    /// touch, and a mixed function.
    static let sample = """
    import Foundation

    struct Calc {
        func addNumbers(_ a: Int, _ b: Int) -> Int {
            let s = a + b
            return s
        }

        func square(_ x: Int) -> Int {
            return multiply(x, x)
        }

        func multiply(_ a: Int, _ b: Int) -> Int {
            return a * b
        }
    }

    struct NetworkService {
        func fetch(_ url: URL) async throws -> Data {
            let (data, _) = try await URLSession.shared.data(from: url)
            return data
        }
    }

    struct Prefs {
        func saveCount(_ n: Int) {
            UserDefaults.standard.set(n, forKey: "count")
        }
    }

    struct Mixer {
        func process(_ values: [Int]) -> Int {
            let total = sum(values)
            let scaled = total * 2
            UserDefaults.standard.set(scaled, forKey: "scaled")
            return scaled
        }

        func sum(_ values: [Int]) -> Int {
            return values.reduce(0, +)
        }
    }
    """

    /// The plan's OrderService, embedded so the tests don't depend on Examples/ path.
    static let orderService = """
    import Foundation

    struct OrderService {
        func calculateOrderTotal(items: [CartItem], promoCode: String?) -> OrderSummary {
            let subtotal = items.reduce(Decimal.zero) { $0 + ($1.price * Decimal($1.quantity)) }
            var discount: Decimal = 0
            if let code = promoCode {
                discount = applyPromoCode(code, subtotal: subtotal)
            }
            let taxableAmount = subtotal - discount
            let tax = taxableAmount * Decimal(0.0875)
            let total = taxableAmount + tax
            return OrderSummary(subtotal: subtotal, discount: discount, tax: tax, total: total)
        }

        func submitOrder(_ order: Order) async throws -> OrderConfirmation {
            guard validateOrder(order) else { throw OrderError.invalidOrder }
            let requestBody = OrderRequest(token: order.paymentToken)
            let (data, _) = try await URLSession.shared.data(for: buildRequest(requestBody))
            let apiResponse = try JSONDecoder().decode(OrderAPIResponse.self, from: data)
            return OrderConfirmation(orderId: apiResponse.id)
        }

        func processLoyaltyPoints(_ user: User, order: OrderSummary) -> LoyaltyResult {
            let basePoints = 10
            let multiplier = loyaltyMultiplier(for: user.tier)
            let earned = basePoints * multiplier
            let newBalance = user.loyaltyPoints + earned
            let newTier = determineTier(points: newBalance)
            UserDefaults.standard.set(newBalance, forKey: "loyalty_points")
            NotificationCenter.default.post(name: .loyaltyTierChanged, object: nil)
            return LoyaltyResult(earned: earned, balance: newBalance, tier: newTier)
        }

        private func applyPromoCode(_ code: String, subtotal: Decimal) -> Decimal {
            return code == "SAVE10" ? subtotal * Decimal(0.10) : 0
        }

        private func validateOrder(_ order: Order) -> Bool {
            return !order.paymentToken.isEmpty
        }

        private func loyaltyMultiplier(for tier: Int) -> Int {
            return tier + 1
        }

        private func determineTier(points: Int) -> Int {
            return points / 1000
        }

        private func calculateDeliveryDate(_ warehouse: String) -> Int {
            return warehouse.count
        }

        private func buildRequest(_ body: OrderRequest) -> URLRequest {
            return URLRequest(url: URL(string: "https://x")!)
        }
    }
    """

    /// A genuinely MIXED function: pure/wasm-safe compute interleaved with a
    /// `mustStayNative` FileManager write. The splitter should lift the pure runs
    /// and keep the FileManager statement in the shell.
    static let exporter = """
    import Foundation

    struct Exporter {
        func export(_ items: [Int], to path: String) -> Int {
            let total = items.reduce(0, +)
            let scaled = total * 2
            let json = try! JSONEncoder().encode(items)
            FileManager.default.createFile(atPath: path, contents: json)
            let report = scaled + items.count
            return report
        }
    }
    """
}
