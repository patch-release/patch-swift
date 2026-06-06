import Foundation
import WasmKit
#if canImport(MessageUI)
import MessageUI
#endif
#if canImport(UIKit)
import UIKit
#endif

// MARK: - MailComposeBridge (system services)
//
// compose_mail(ptr,len) — present the iOS mail compose sheet. The guest passes a
// JSON object `{"to":["a@b.com"],"subject":"…","body":"…"}` (all fields
// optional) as `(ptr,len)`; the host decodes it into a `MailDraft` and hands it
// to an injected handler. Fire-and-forget: no result is returned to the guest.
//
// Like NavigationBridge / ShareSheetBridge, the native capability is injected as
// a `@Sendable` closure so the bridge compiles + unit-tests on macOS (no
// MessageUI / UIKit at the top level). The cross-platform designated
// `init(compose:)` takes the handler the tests inject; the
// `#if canImport(MessageUI)` convenience `init()` wires the real
// `MFMailComposeViewController`, presented from the key window's top view
// controller (only when `MFMailComposeViewController.canSendMail()`).

/// A parsed email draft handed to the injected compose handler. All fields are
/// optional in the wire format; `to` defaults to empty, `subject`/`body` to nil.
public struct MailDraft: Sendable {
    public let to: [String]
    public let subject: String?
    public let body: String?

    public init(to: [String], subject: String?, body: String?) {
        self.to = to
        self.subject = subject
        self.body = body
    }
}

public struct MailComposeBridge: Bridge {
    /// The injected native capability: present a mail compose sheet for the
    /// given draft. Fire-and-forget.
    public typealias Handler = @Sendable (_ draft: MailDraft) -> Void

    public let module = "patch"
    private let compose: Handler

    /// Cross-platform designated init. Tests inject a spy that records the
    /// decoded `MailDraft`; apps can inject any custom presenter.
    public init(compose: @escaping Handler) { self.compose = compose }

    #if canImport(MessageUI)
    /// Convenience default init that presents a real
    /// `MFMailComposeViewController` from the key window's top view controller,
    /// only when the device is configured to send mail. iOS-only.
    public init() {
        self.init(compose: { draft in
            MailComposeBridge.presentMailComposer(draft)
        })
    }
    #endif

    /// Decode the compose JSON payload into a `MailDraft`.
    ///
    /// `to` is read as an array of strings (each element coerced via `as?
    /// String`; non-string elements dropped). A missing `to` key, or a non-array
    /// `to` value, yields an empty recipient list. Missing `subject`/`body`
    /// keys, or non-string values, yield nil. Invalid / non-object JSON →
    /// `MailDraft(to: [], subject: nil, body: nil)`. Pulled out as a pure
    /// `static` func so the decode is unit-tested directly (per the bridge guide).
    public static func parse(_ bytes: [UInt8]) -> MailDraft {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any] else {
            return MailDraft(to: [], subject: nil, body: nil)
        }
        let to: [String]
        if let arr = obj["to"] as? [Any] {
            to = arr.compactMap { $0 as? String }
        } else {
            // missing key or non-array value → empty recipient list
            to = []
        }
        let subject = obj["subject"] as? String
        let body = obj["body"] as? String
        return MailDraft(to: to, subject: subject, body: body)
    }

    public func register(into imports: inout Imports, store: Store) {
        let compose = self.compose
        imports.host(module, "compose_mail", [.i32, .i32], [], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let bytes = try ctx.readBytes(ptr: args[0].i32, len: args[1].i32)
            let draft = Self.parse(bytes)
            compose(draft)
            return []
        }
    }

    #if canImport(MessageUI)
    /// Present a real `MFMailComposeViewController` from the key window's top
    /// view controller on the main thread. No-op if the device cannot send mail
    /// or there is no window to present from.
    @MainActor
    private static func presentMailComposer(_ draft: MailDraft) {
        guard MFMailComposeViewController.canSendMail() else { return }
        guard let presenter = topViewController() else { return }
        let vc = MFMailComposeViewController()
        vc.mailComposeDelegate = MailComposeDismisser.shared
        if !draft.to.isEmpty { vc.setToRecipients(draft.to) }
        if let subject = draft.subject { vc.setSubject(subject) }
        if let body = draft.body { vc.setMessageBody(body, isHTML: false) }
        presenter.present(vc, animated: true)
    }

    /// Walk from the key window's root to the topmost presented/visible view
    /// controller so the composer is presented from the right place.
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

#if canImport(MessageUI)
/// `MFMailComposeViewController` requires a delegate to dismiss itself when the
/// user finishes/cancels. A single shared dismisser handles that (the bridge is
/// fire-and-forget, so there is no result to route back to the guest).
private final class MailComposeDismisser: NSObject, MFMailComposeViewControllerDelegate {
    @MainActor static let shared = MailComposeDismisser()

    func mailComposeController(
        _ controller: MFMailComposeViewController,
        didFinishWith result: MFMailComposeResult,
        error: Error?
    ) {
        controller.dismiss(animated: true)
    }
}
#endif
