import Foundation
import WasmKit
#if canImport(UIKit)
import UIKit
#endif

// MARK: - AppShortcutsBridge (dynamic home-screen quick actions)
//
// `set_shortcuts(ptr,len) -> []` — replace the app's dynamic home-screen quick
// actions (the menu shown on a long-press of the app icon). The guest passes a
// JSON array as `(ptr,len)`; the host decodes it into `[QuickAction]` and hands
// them to an injected setter. Fire-and-forget — no result is returned to the
// guest (like NavigationBridge.navigate / MailComposeBridge.compose_mail).
//
// Wire format (each element; `type` required, the rest optional):
//   [{"type":"com.acme.new","title":"New Item","subtitle":"Create",
//     "systemImageName":"plus","userInfo":{"k":"v"}}]
//
// ## Cross-platform core + injected dependency (Rule 2)
// `UIApplicationShortcutItem` / `UIApplication.shortcutItems` are UIKit-only, so
// the native capability is injected as a `@Sendable ([QuickAction]) -> Void`
// setter. The bridge struct + its `register(...)` + the JSON decode therefore
// compile on macOS (no direct UIKit at the top level); tests inject a spy and
// assert the decoded actions. The convenience `init()` maps `[QuickAction]` to
// `[UIApplicationShortcutItem]` and assigns `UIApplication.shared.shortcutItems`
// on the main thread, guarded by `#if canImport(UIKit)`.

/// A single dynamic quick action. `type` is the identifier delivered back to the
/// app when the user taps the action; the rest are display / payload metadata.
public struct QuickAction: Sendable, Equatable {
    public let type: String
    public let title: String
    public let subtitle: String?
    public let systemImageName: String?
    public let userInfo: [String: String]

    public init(
        type: String,
        title: String,
        subtitle: String?,
        systemImageName: String?,
        userInfo: [String: String]
    ) {
        self.type = type
        self.title = title
        self.subtitle = subtitle
        self.systemImageName = systemImageName
        self.userInfo = userInfo
    }
}

public struct AppShortcutsBridge: Bridge {
    /// The injected native capability: install the given dynamic quick actions.
    public typealias Setter = @Sendable (_ actions: [QuickAction]) -> Void

    public let module = "patch"
    private let setShortcuts: Setter

    /// Cross-platform designated init — tests inject a spy here.
    public init(setShortcuts: @escaping Setter) {
        self.setShortcuts = setShortcuts
    }

    #if canImport(UIKit)
    /// Convenience default init wiring the real UIApplication quick-action API.
    /// Maps each `QuickAction` to a `UIApplicationShortcutItem` (with an SF Symbol
    /// icon when `systemImageName` is set) and assigns the array on the main
    /// thread. Guarded by `canImport(UIKit)` so the macOS host build never
    /// references UIKit.
    public init() {
        self.init(setShortcuts: { actions in
            let items: [UIApplicationShortcutItem] = actions.map { action in
                let icon = action.systemImageName.map {
                    UIApplicationShortcutIcon(systemImageName: $0)
                }
                return UIApplicationShortcutItem(
                    type: action.type,
                    localizedTitle: action.title,
                    localizedSubtitle: action.subtitle,
                    icon: icon,
                    userInfo: action.userInfo as [String: NSSecureCoding])
            }
            let apply: @Sendable () -> Void = {
                UIApplication.shared.shortcutItems = items
            }
            if Thread.isMainThread { apply() } else { DispatchQueue.main.async { apply() } }
        })
    }
    #endif

    /// Decode the shortcuts JSON array into `[QuickAction]`.
    ///
    /// Each element must be an object with a non-empty `type`; elements missing a
    /// usable `type` are dropped. `title` defaults to the `type` when absent.
    /// `subtitle` / `systemImageName` are optional strings. `userInfo` is read as
    /// a string→string map (non-string values are dropped). Invalid / non-array
    /// JSON yields an empty array (which clears all dynamic shortcuts). Pulled out
    /// as a pure `static` func so the decode is unit-tested directly.
    public static func parse(_ bytes: [UInt8]) -> [QuickAction] {
        guard let arr = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [Any] else {
            return []
        }
        return arr.compactMap { element -> QuickAction? in
            guard let obj = element as? [String: Any],
                  let type = obj["type"] as? String, !type.isEmpty
            else { return nil }
            let title = (obj["title"] as? String) ?? type
            let subtitle = obj["subtitle"] as? String
            let systemImageName = obj["systemImageName"] as? String
            var userInfo: [String: String] = [:]
            if let raw = obj["userInfo"] as? [String: Any] {
                for (k, v) in raw {
                    if let s = v as? String { userInfo[k] = s }
                }
            }
            return QuickAction(
                type: type, title: title, subtitle: subtitle,
                systemImageName: systemImageName, userInfo: userInfo)
        }
    }

    public func register(into imports: inout Imports, store: Store) {
        let setShortcuts = self.setShortcuts
        imports.host(module, "set_shortcuts", [.i32, .i32], [], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let bytes = try ctx.readBytes(ptr: args[0].i32, len: args[1].i32)
            setShortcuts(Self.parse(bytes))
            return []
        }
    }
}
