import Foundation
#if canImport(ObjectiveC)
import ObjectiveC
#endif
#if canImport(UIKit)
import UIKit
#endif

/// The on-device **name-lookup redirection** for the resource overlay (Phase 1b).
///
/// When a patch carries a resource overlay (`PatchResourceOverlay.Table`), the SDK
/// installs this redirection: the shipped named-lookup accessors —
/// `UIColor(named:)`, `UIImage(named:)`, and `Bundle.localizedString(forKey:value:table:)`
/// (which backs `NSLocalizedString`) — consult the ACTIVE overlay FIRST and, only on a
/// miss, fall through to the app bundle. The redirection is installed by ObjC
/// **method swizzling** of those *shipped* symbols (so it is zero dev work and adds no
/// App-Store-review surface — the code is compiled into the signed app; only the
/// overlay DATA changes at runtime).
///
/// ## What's overridable
/// - **Colors** (`UIColor(named:)`, and SwiftUI `Color("name")` which resolves through
///   `UIColor(named:)` on UIKit platforms) — FULLY.
/// - **Localized strings** (`NSLocalizedString` / `Bundle.localizedString`) — FULLY,
///   locale-aware (per-locale tables + base fallback).
/// - **Images** (`UIImage(named:)`) — the redirect path is wired; inline image bytes
///   work but carry an HONEST SIZE CAVEAT (large payloads bloat the artifact — prefer
///   the external-ref form for big assets).
///
/// ## Activation / rollback (clean by construction)
/// `setActiveOverlay(_:)` swaps the active table under a lock and lazily installs the
/// swizzles the first time a non-nil overlay appears. Swizzles, once installed, stay
/// installed for the process lifetime (uninstalling a swizzle racing in-flight callers
/// is unsafe); instead **rollback is a DATA operation** — `setActiveOverlay(nil)`
/// clears the table so every swizzled accessor immediately falls through to the
/// original implementation (the bundle), exactly as if no overlay were present. The
/// saved original IMPs are always invoked on a miss, so an un-overridden name behaves
/// identically whether or not the overlay is active.
///
/// Where ObjC swizzling is unavailable (a symbol that is not an `@objc dynamic`
/// accessor — e.g. the pure-Swift SwiftUI `Color(_:bundle:)` initializer), the SDK
/// exposes a documented lookup API on `Patch` (`Patch.overlayColor(named:)` /
/// `overlayLocalizedString(...)`) the host can call directly.
public final class ResourceOverlayRedirect: @unchecked Sendable {

    /// Process-wide redirection. The SDK has exactly one active overlay at a time
    /// (the active module's), so a singleton is the right shape — the swizzled
    /// accessors are global and must read ONE source of truth.
    public static let shared = ResourceOverlayRedirect()

    private let lock = NSLock()
    private var active: PatchResourceOverlay.Table?
    private var installed = false

    init() {}

    // MARK: - Active overlay (set by Patch.activate / cleared on rollback)

    /// Swap the active overlay table. Passing a non-nil table lazily installs the
    /// swizzles (once). Passing nil clears the overlay so every accessor falls through
    /// to the bundle (the rollback / deactivate path).
    public func setActiveOverlay(_ table: PatchResourceOverlay.Table?) {
        lock.lock()
        active = (table?.isEmpty == true) ? nil : table
        let needInstall = (active != nil) && !installed
        if needInstall { installed = true }
        lock.unlock()
        if needInstall { Self.installSwizzles() }
    }

    /// The active overlay table (nil when none / rolled back). Read path for the
    /// swizzled accessors + the `Patch` fallback API.
    public func currentOverlay() -> PatchResourceOverlay.Table? {
        lock.lock(); defer { lock.unlock() }
        return active
    }

    /// Whether an overlay is currently active.
    public var hasActiveOverlay: Bool { currentOverlay() != nil }

    // MARK: - Lookup (the read path the swizzles + fallback API share)

    /// The overridden color for `name`, resolved for the given dark-mode flag. nil =
    /// no override (caller falls through to the bundle).
    func colorComponents(named name: String, dark: Bool) -> PatchResourceOverlay.RGBA? {
        guard let c = currentOverlay()?.color(named: name) else { return nil }
        if dark, let d = c.dark { return d }
        return c.light
    }

    /// The overridden localized string for `key`, or nil (fall through to the bundle).
    func localizedString(forKey key: String, table: String?, locale: String?) -> String? {
        currentOverlay()?.string(forKey: key, table: table, locale: locale)
    }

    /// The overridden image bytes for `name` (inline kind only), or nil.
    func imageBytes(named name: String) -> [UInt8]? {
        guard let img = currentOverlay()?.image(named: name), img.kind == .inline else { return nil }
        return img.payload
    }

    // MARK: - Swizzle installation

    /// Install the ObjC swizzles for the named-lookup accessors. Idempotent + only
    /// ever called once (guarded by `installed`). On platforms without UIKit only the
    /// Foundation `Bundle.localizedString` swizzle is installed.
    static func installSwizzles() {
        OverlaySwizzles.installAll()
    }
}

#if canImport(ObjectiveC)

/// The concrete ObjC method swizzles. Kept in a separate type so the `#if canImport`
/// guards are localized and the swizzle bookkeeping (saved original IMPs) is tidy.
enum OverlaySwizzles {

    /// Swap the implementations of two INSTANCE methods on `cls`. Returns false if
    /// either selector is missing.
    @discardableResult
    static func swizzleInstanceMethod(_ cls: AnyClass, _ original: Selector, _ replacement: Selector) -> Bool {
        guard let origM = class_getInstanceMethod(cls, original),
              let replM = class_getInstanceMethod(cls, replacement) else { return false }
        method_exchangeImplementations(origM, replM)
        return true
    }

    /// Swap the implementations of two CLASS methods on `cls`. ObjC class methods live
    /// on the metaclass, so this resolves them with `class_getClassMethod` and
    /// exchanges. Used for `UIColor`/`UIImage`'s `init(named:in:compatibleWith:)`,
    /// which bridge from the ObjC class factories `+colorNamed:…` / `+imageNamed:…`
    /// (class methods, NOT instance methods). Returns false if either is missing.
    @discardableResult
    static func swizzleClassMethod(_ cls: AnyClass, _ original: Selector, _ replacement: Selector) -> Bool {
        guard let origM = class_getClassMethod(cls, original),
              let replM = class_getClassMethod(cls, replacement) else { return false }
        method_exchangeImplementations(origM, replM)
        return true
    }

    static func installAll() {
        installBundleStrings()
        #if canImport(UIKit)
        installUIColor()
        installUIImage()
        #endif
    }

    // MARK: Foundation — Bundle.localizedString(forKey:value:table:)

    static func installBundleStrings() {
        // `localizedString(forKey:value:table:)` is an `@objc` method on `Bundle`
        // (NSBundle) — swizzlable. Our replacement (the `patch_` category method on
        // Bundle below) checks the overlay first, else calls the saved original.
        swizzleInstanceMethod(
            Bundle.self,
            #selector(Bundle.localizedString(forKey:value:table:)),
            #selector(Bundle.patch_localizedString(forKey:value:table:)))
    }

    #if canImport(UIKit)

    // MARK: UIKit — UIColor(named:) and UIImage(named:)

    static func installUIColor() {
        // `UIColor(named:)` and `UIColor(named:in:compatibleWith:)` are DISTINCT ObjC
        // class factories (`+colorNamed:` vs `+colorNamed:inBundle:compatibleWith…`) —
        // the common 1-arg call does NOT go through the 3-arg one. Swizzle BOTH (each a
        // class method) so direct `UIColor(named:)` calls AND SwiftUI `Color("name")`
        // (which resolves via the asset catalog through UIColor) are redirected.
        swizzleClassMethod(
            UIColor.self,
            #selector(UIColor.init(named:)),
            #selector(UIColor.patch_initNamed1(_:)))
        swizzleClassMethod(
            UIColor.self,
            #selector(UIColor.init(named:in:compatibleWith:)),
            #selector(UIColor.patch_init(named:in:compatibleWith:)))
    }

    static func installUIImage() {
        // Likewise `UIImage(named:)` (`+imageNamed:`) is distinct from the 3-arg
        // `+imageNamed:inBundle:compatibleWith…`; swizzle both class factories.
        swizzleClassMethod(
            UIImage.self,
            #selector(UIImage.init(named:)),
            #selector(UIImage.patch_initNamed1(_:)))
        swizzleClassMethod(
            UIImage.self,
            #selector(UIImage.init(named:in:compatibleWith:)),
            #selector(UIImage.patch_init(named:in:compatibleWith:)))
    }

    #endif
}

// MARK: - Swizzled accessors

extension Bundle {
    /// Swizzled stand-in for `localizedString(forKey:value:table:)`. After the
    /// `method_exchangeImplementations`, a call to `localizedString(...)` lands HERE,
    /// and calling `patch_localizedString(...)` inside this body invokes the ORIGINAL
    /// implementation (the selectors are swapped). So: overlay first, else the bundle.
    @objc func patch_localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        if let override = ResourceOverlayRedirect.shared.localizedString(
            forKey: key, table: tableName, locale: Self.patchPreferredLocale) {
            return override
        }
        // Fall through to the original (selectors are swapped post-swizzle).
        return self.patch_localizedString(forKey: key, value: value, table: tableName)
    }

    /// The device's preferred localization (e.g. "fr", "pt-BR"), used to resolve the
    /// overlay's per-locale string tables. `Locale.preferredLanguages.first` reflects
    /// what `NSLocalizedString` would itself resolve against.
    static var patchPreferredLocale: String? {
        Locale.preferredLanguages.first
    }
}

#if canImport(UIKit)

extension UIColor {
    /// Swizzled stand-in for the 1-arg `init(named:)` (`+colorNamed:`).
    @objc class func patch_initNamed1(_ name: String) -> UIColor? {
        if ResourceOverlayRedirect.shared.currentOverlay()?.color(named: name) != nil {
            return patchOverlayColor(named: name)
        }
        return UIColor.patch_initNamed1(name)   // original (selectors swapped)
    }

    /// Swizzled stand-in for `init(named:in:compatibleWith:)`. Returns the overlay
    /// color when one is registered for `name`, else the original asset-catalog color.
    @objc class func patch_init(named name: String, in bundle: Bundle?, compatibleWith traits: UITraitCollection?) -> UIColor? {
        if ResourceOverlayRedirect.shared.currentOverlay()?.color(named: name) != nil {
            return patchOverlayColor(named: name)
        }
        // Selectors are swapped post-swizzle → this calls the ORIGINAL init.
        return UIColor.patch_init(named: name, in: bundle, compatibleWith: traits)
    }

    /// Build a `UIColor` from the overlay override for `name`. When a dark variant is
    /// present the result is a dynamic color that resolves per the trait collection's
    /// `userInterfaceStyle`; otherwise it's a plain sRGB color.
    static func patchOverlayColor(named name: String) -> UIColor? {
        guard let c = ResourceOverlayRedirect.shared.currentOverlay()?.color(named: name) else { return nil }
        let light = UIColor(red: CGFloat(c.light.r), green: CGFloat(c.light.g),
                            blue: CGFloat(c.light.b), alpha: CGFloat(c.light.a))
        guard let d = c.dark else { return light }
        let dark = UIColor(red: CGFloat(d.r), green: CGFloat(d.g), blue: CGFloat(d.b), alpha: CGFloat(d.a))
        #if os(iOS) || os(tvOS)
        if #available(iOS 13.0, tvOS 13.0, *) {
            return UIColor { traits in traits.userInterfaceStyle == .dark ? dark : light }
        }
        #endif
        return light
    }
}

extension UIImage {
    /// Swizzled stand-in for the 1-arg `init(named:)` (`+imageNamed:`).
    @objc class func patch_initNamed1(_ name: String) -> UIImage? {
        if let img = ResourceOverlayRedirect.patchOverlayImage(named: name) { return img }
        return UIImage.patch_initNamed1(name)   // original (selectors swapped)
    }

    /// Swizzled stand-in for `init(named:in:compatibleWith:)`. Returns an image built
    /// from the overlay's inline bytes when one is registered, else the original
    /// asset-catalog image. (External-ref overrides fall through — their bytes are not
    /// inline; see the size caveat in `PatchResourceOverlay`.)
    @objc class func patch_init(named name: String, in bundle: Bundle?, compatibleWith traits: UITraitCollection?) -> UIImage? {
        if let img = ResourceOverlayRedirect.patchOverlayImage(named: name) { return img }
        // Selectors are swapped post-swizzle → this calls the ORIGINAL init.
        return UIImage.patch_init(named: name, in: bundle, compatibleWith: traits)
    }
}

extension ResourceOverlayRedirect {
    /// Build a `UIImage` from the overlay's inline override for `name`, or nil. Shared
    /// by both swizzled `UIImage` factories.
    static func patchOverlayImage(named name: String) -> UIImage? {
        guard let bytes = shared.imageBytes(named: name) else { return nil }
        let scale = shared.currentOverlay()?.image(named: name)?.scale ?? 0
        return UIImage(data: Data(bytes), scale: scale == 0 ? 1 : CGFloat(scale))
    }
}

#endif  // canImport(UIKit)

#endif  // canImport(ObjectiveC)
