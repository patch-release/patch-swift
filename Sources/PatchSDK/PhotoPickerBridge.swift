import Foundation
import WasmKit
#if canImport(UIKit)
import UIKit
// PhotosUI is only used to drive a real UIKit-presented PHPickerViewController.
// Gating the import on UIKit too keeps the macOS host build from pulling SwiftUI
// (which PhotosUI re-exports) into the module's overload namespace, where its
// `Optional: Gesture` conformance would collide with Marshalling's generic
// `Optional: WASMBridgeable`.
#if canImport(PhotosUI)
import PhotosUI
#endif
#endif

// MARK: - PhotoPickerBridge (system frameworks — Photos)
//
// present_photo_picker(ptr,len) — present the iOS photo picker. The guest passes
// a JSON object `{"limit":1,"filter":"images|videos|any"}` (all optional) as
// `(ptr,len)`; the host decodes it into a `PhotoPickerRequest` and hands that to
// an injected handler. Fire-and-forget: no result is returned to the guest. The
// selected image is delivered to the app NATIVELY (the shell presents the picker
// and routes the chosen media through its own delegate), exactly mirroring how
// `NavigationBridge` and `ShareSheetBridge` model interactive UI.
//
// Per the bridge guide's TWO HARD RULES: the native capability is injected as a
// `@Sendable` closure so the struct + its `register(...)` marshalling compile and
// unit-test on macOS (no PhotosUI/UIKit at the top level). The cross-platform
// designated `init(present:)` takes the handler the tests inject; the
// `#if canImport(PhotosUI)` convenience `init()` wires a real
// `PHPickerViewController`, configured from the request's filter/limit and
// presented from the key window's top view controller.
public struct PhotoPickerBridge: Bridge {
    /// The injected native capability: present a photo picker for the given
    /// request (selection limit + media filter).
    public typealias Handler = @Sendable (_ request: PhotoPickerRequest) -> Void

    public let module = "patch"
    private let present: Handler

    /// Cross-platform designated init. Tests inject a spy that records the
    /// decoded `PhotoPickerRequest`; apps can inject any custom presenter.
    public init(present: @escaping Handler) { self.present = present }

    #if canImport(PhotosUI) && canImport(UIKit)
    /// Convenience default init that presents a real `PHPickerViewController`
    /// from the key window's top view controller, configured with the request's
    /// filter/limit. iOS-family only (PhotosUI + UIKit). On the macOS host build
    /// PhotosUI is intentionally not imported (see the import note above), so this
    /// convenience init is absent there and tests use `init(present:)`.
    public init() {
        self.init(present: { request in
            // The host call is synchronous + nonisolated; hop to the main actor
            // to drive UIKit/PhotosUI presentation. Fire-and-forget, so we don't
            // wait for completion.
            Task { @MainActor in
                PhotoPickerBridge.presentPicker(request)
            }
        })
    }
    #endif

    /// Decode the picker JSON payload into a `PhotoPickerRequest`.
    ///
    /// All fields are optional. Defaults: `limit = 1`, `filter = "images"`.
    /// `limit` is clamped to `>= 1` (a 0 / negative / non-number selection limit
    /// is meaningless for a picker). `filter` is normalized (lowercased, trimmed)
    /// to one of `"images"`, `"videos"`, `"any"`; anything else falls back to the
    /// default `"images"`. Invalid / non-object JSON → the all-defaults request.
    /// Pulled out as a pure `static` func so the decode is unit-tested directly
    /// (per the bridge guide).
    public static func parse(_ bytes: [UInt8]) -> PhotoPickerRequest {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any] else {
            return PhotoPickerRequest(limit: 1, filter: "images")
        }
        let limit: Int
        if let n = obj["limit"] as? NSNumber {
            limit = max(1, n.intValue)
        } else {
            limit = 1
        }
        let filter = normalizeFilter(obj["filter"] as? String)
        return PhotoPickerRequest(limit: limit, filter: filter)
    }

    /// Normalize a raw filter string to one of the three accepted values, falling
    /// back to `"images"` for nil / unknown input. Lowercases + trims first so
    /// `" Images "` and `"VIDEOS"` are accepted.
    static func normalizeFilter(_ raw: String?) -> String {
        guard let raw else { return "images" }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "images": return "images"
        case "videos": return "videos"
        case "any": return "any"
        default: return "images"
        }
    }

    public func register(into imports: inout Imports, store: Store) {
        let present = self.present
        imports.host(module, "present_photo_picker", [.i32, .i32], [], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let bytes = try ctx.readBytes(ptr: args[0].i32, len: args[1].i32)
            present(Self.parse(bytes))
            return []
        }
    }

    #if canImport(PhotosUI) && canImport(UIKit)
    /// Build a `PHPickerConfiguration` from the request and present a
    /// `PHPickerViewController` from the key window's top view controller on the
    /// main thread. No-op if there is no window. Selection is delivered to the
    /// app's own `PHPickerViewControllerDelegate` (the shell owns that), so this
    /// bridge stays fire-and-forget.
    @MainActor
    private static func presentPicker(_ request: PhotoPickerRequest) {
        guard let presenter = topViewController() else { return }
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.selectionLimit = max(1, request.limit)
        switch request.filter {
        case "videos": config.filter = .videos
        case "any": config.filter = .any(of: [.images, .videos])
        default: config.filter = .images
        }
        let vc = PHPickerViewController(configuration: config)
        // The shell installs its own delegate to receive the picked media; if it
        // hasn't, the presented controller is still valid (user can cancel).
        presenter.present(vc, animated: true)
    }
    #endif

    #if canImport(UIKit)
    /// Walk from the key window's root to the topmost presented/visible view
    /// controller so the picker is presented from the right place.
    @MainActor
    private static func topViewController() -> UIViewController? {
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        var top = keyWindow?.rootViewController
        while true {
            if let presented = top?.presentedViewController {
                top = presented
            } else if let nav = top as? UINavigationController {
                top = nav.visibleViewController ?? nav.topViewController
            } else if let tab = top as? UITabBarController {
                top = tab.selectedViewController ?? top
            } else {
                break
            }
        }
        return top
    }
    #endif
}

/// A decoded photo-picker request: how many items the user may select and which
/// media kinds to show. `Sendable` so it crosses the injected handler boundary.
public struct PhotoPickerRequest: Sendable, Equatable {
    /// Maximum number of items the user may select (always `>= 1`).
    public let limit: Int
    /// Media filter — one of `"images"`, `"videos"`, `"any"`.
    public let filter: String

    public init(limit: Int, filter: String) {
        self.limit = limit
        self.filter = filter
    }
}
