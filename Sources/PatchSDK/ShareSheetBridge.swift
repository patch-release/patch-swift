import Foundation
import WasmKit
#if canImport(UIKit)
import UIKit
#endif

// MARK: - ShareSheetBridge (system services)
//
// share(ptr,len) — present the iOS share sheet. The guest passes a JSON object
// `{"text":"…","url":"https://…"}` (either/both optional) as `(ptr,len)`; the
// host decodes it and hands the resulting `(text, url)` pair to an injected
// handler. Fire-and-forget: no result is returned to the guest.
//
// Like NavigationBridge, the native capability is injected as a `@Sendable`
// closure so the bridge compiles + unit-tests on macOS (no UIKit at the top
// level). The cross-platform designated `init(present:)` takes the handler the
// tests inject; the `#if canImport(UIKit)` convenience `init()` wires the real
// `UIActivityViewController`, presented from the key window's top view
// controller.
public struct ShareSheetBridge: Bridge {
    /// The injected native capability: present a share sheet for the given
    /// (text, url). Both are optional; at least one is typically non-nil.
    public typealias Handler = @Sendable (_ text: String?, _ url: String?) -> Void

    public let module = "patch"
    private let present: Handler

    /// Cross-platform designated init. Tests inject a spy that records the
    /// decoded (text, url); apps can inject any custom presenter.
    public init(present: @escaping Handler) { self.present = present }

    #if canImport(UIKit)
    /// Convenience default init that presents a real `UIActivityViewController`
    /// from the key window's top view controller. iOS-only.
    public init() {
        self.init(present: { text, url in
            ShareSheetBridge.presentActivityController(text: text, url: url)
        })
    }
    #endif

    /// Decode the share JSON payload into an optional (text, url) pair.
    ///
    /// Missing keys → nil; a non-string value for a key is treated as absent.
    /// Invalid / non-object JSON → (nil, nil). Pulled out as a pure `static`
    /// func so the decode is unit-tested directly (per the bridge guide).
    public static func parse(_ bytes: [UInt8]) -> (text: String?, url: String?) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any] else {
            return (nil, nil)
        }
        let text = obj["text"] as? String
        let url = obj["url"] as? String
        return (text, url)
    }

    public func register(into imports: inout Imports, store: Store) {
        let present = self.present
        imports.host(module, "share", [.i32, .i32], [], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let bytes = try ctx.readBytes(ptr: args[0].i32, len: args[1].i32)
            let (text, url) = Self.parse(bytes)
            present(text, url)
            return []
        }
    }

    #if canImport(UIKit)
    /// Build the activity items from (text, url) and present a
    /// `UIActivityViewController` from the key window's top view controller on
    /// the main thread. No-op if there is nothing to share or no window.
    @MainActor
    private static func presentActivityController(text: String?, url: String?) {
        var items: [Any] = []
        if let text { items.append(text) }
        if let url, let u = URL(string: url) { items.append(u) }
        guard !items.isEmpty else { return }
        guard let presenter = topViewController() else { return }
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        // iPad requires a source for the popover; anchor to the presenter's view.
        vc.popoverPresentationController?.sourceView = presenter.view
        presenter.present(vc, animated: true)
    }

    /// Walk from the key window's root to the topmost presented/visible view
    /// controller so the sheet is presented from the right place.
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
