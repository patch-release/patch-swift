import Foundation
import WasmKit
// NOTE: StoreKit / UIKit are imported ONLY on real device platforms (iOS / tvOS).
// We deliberately do NOT import them on macOS: on macOS StoreKit transitively
// re-exports SwiftUI, whose `extension Optional: Gesture` then collides with this
// module's `extension Optional: WASMBridgeable` (Marshalling.swift) during
// whole-module type-checking. The macOS host build is the test build, and tests
// inject the native action as a closure (Rule 2), so the real StoreKit path is
// never needed there. On iOS the convenience init wires the real prompt.
#if os(iOS) || os(tvOS) || os(visionOS)
import StoreKit
import UIKit
#endif

// MARK: - appReview (in-app rating prompt) bridge
//
// `request_review()` — asks the OS to surface the standard "rate this app"
// prompt. Fire-and-forget: there is no result the guest can act on (the OS
// decides whether/when to actually show the sheet, and rate-limits it), so the
// host function takes no args and returns nothing.
//
// Cross-platform core + injected dependency (guide Rule 2): the bridge stores a
// `@Sendable () -> Void` so the whole struct + its `register(...)` marshalling
// compiles on macOS (where the native StoreKit import is intentionally absent —
// see the import note above). Tests inject a spy closure and assert the
// registered host function invokes it exactly once per call. The convenience
// `init()` (device platforms only) wires the real StoreKit call:
// `AppStore.requestReview(in:)` on newer OS, else
// `SKStoreReviewController.requestReview(in:)`.
//
// Mirrors `NavigationBridge` (injected handler, fire-and-forget void import).
public struct AppReviewBridge: Bridge {
    /// The native "show the rating prompt" action. Injected so the bridge is
    /// testable on macOS; the convenience init supplies the real StoreKit one.
    public typealias RequestReview = @Sendable () -> Void

    public let module = "patch"
    private let request: RequestReview

    /// Cross-platform designated init — tests inject a spy here.
    public init(request: @escaping RequestReview) {
        self.request = request
    }

    #if os(iOS) || os(tvOS) || os(visionOS)
    /// Convenience default init: wire the real OS rating prompt. The actual
    /// presentation hops to the main thread because StoreKit's review APIs are
    /// main-thread / UI bound.
    public init() {
        self.init(request: { Self.requestReviewNative() })
    }

    /// Real StoreKit invocation, isolated so the cross-platform core stays clean.
    /// Prefers the modern `AppStore.requestReview(in:)` (iOS 16+) using the active
    /// foreground window scene, falling back to the older
    /// `SKStoreReviewController.requestReview(in:)`.
    private static func requestReviewNative() {
        // Concurrency hop: `AppStore.requestReview(in:)` (and the scene lookup via
        // `UIApplication.shared`) are main-actor-isolated, but this is called from
        // the synchronous, nonisolated `@Sendable` import closure. Hop the WHOLE
        // body onto the main actor with `Task { @MainActor in … }` (fire-and-forget
        // — the review prompt has no result the guest can act on). We use a Task
        // rather than `MainActor.assumeIsolated`, which is iOS 17+, to keep the
        // SDK's iOS 16 floor.
        Task { @MainActor in
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            guard let scene = scenes.first(where: { $0.activationState == .foregroundActive })
                ?? scenes.first
            else { return }
            if #available(iOS 16.0, tvOS 16.0, *) {
                AppStore.requestReview(in: scene)
            } else {
                SKStoreReviewController.requestReview(in: scene)
            }
        }
    }
    #endif

    public func register(into imports: inout Imports, store: Store) {
        let request = self.request
        // request_review() -> [] : fire-and-forget; no args, no result.
        imports.host(module, "request_review", [], [], store: store) { _, _ in
            request()
            return []
        }
    }
}
