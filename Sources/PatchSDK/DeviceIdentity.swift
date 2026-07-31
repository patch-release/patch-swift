// SPDX-License-Identifier: MIT

import Foundation

/// The SDK's **stable anonymous device identifier**.
///
/// Every update check and telemetry event carries a `device_id`. The backend
/// uses it for three load-bearing things:
///
/// * **staged rollouts** — bucketing is `sha256(device_id + version) % 100`, so
///   two devices only land in different buckets if they report different ids;
/// * **cohort derivation** — a stable hash-bucket cohort when the app doesn't
///   set one explicitly;
/// * **active-device counting** — the plan device-cap and the billable usage
///   metric both count DISTINCT `device_id`s.
///
/// Historically `PatchConfiguration.deviceID` defaulted to `nil` and the wire
/// payload fell back to the literal `"anon"`. Nothing in the SDK ever populated
/// it, and the `Patch.configure(…)` call written by `patchcli init` doesn't pass
/// it either — so every device in such an app reported the SAME id. Because the
/// bucketer hashes that id, every device landed in the SAME bucket: a "10%
/// rollout" was a fleet-wide all-or-nothing coin flip per version rather than a
/// percentage. This type is the fix.
///
/// **What it is:** a random UUID minted on first use and persisted in
/// `UserDefaults`. It is derived from no hardware identifier, no advertising
/// identifier, and needs no `identifierForVendor` (which would drag in UIKit,
/// which this SDK deliberately avoids — see the note at the top of `Patch.swift`)
/// and no tracking-authorization prompt. It resets if the user deletes the app,
/// which is the correct behaviour for a fresh install.
///
/// > It is nevertheless a **persistent pseudonymous identifier** transmitted to a
/// > server and used as a billing join key, so treat it as personal data for
/// > GDPR purposes (Recital 26: pseudonymisation is not anonymisation). Do not
/// > describe it publicly as carrying "no personal data".
///
/// **App groups (important).** An iOS app extension — widget, share extension,
/// notification-service extension — has its own `UserDefaults` preferences
/// domain. Left at `.standard` each extension would mint a SEPARATE id, which
/// would (a) count one user as several devices against the plan cap and against
/// billing, and (b) put the widget in a different rollout bucket from its host
/// app, so the two could run different patch versions. Set
/// `PatchConfiguration.appGroupIdentifier` in every target that configures Patch
/// and they share one identity.
///
/// An app that wants its own identity scheme still sets
/// `PatchConfiguration.deviceID` explicitly; that always wins.
public final class PatchDeviceIDStore: @unchecked Sendable {

    /// The store backed by `UserDefaults.standard` (no app group configured).
    public static let shared = PatchDeviceIDStore(defaults: .standard)

    /// The `UserDefaults` key the identifier is persisted under.
    public static let defaultsKey = "com.patchrelease.patchsdk.deviceID"

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var cached: String?

    /// Cross-platform designated init — tests inject an isolated `UserDefaults`
    /// so they never read or write the real suite (mirrors `AppGroupStorage`).
    public init(defaults: UserDefaults) { self.defaults = defaults }

    /// The stable id for this install, minting and persisting one on first call.
    ///
    /// Thread-safe and idempotent: concurrent first calls mint exactly one id.
    /// After the first call the value is served from memory, so the hot update
    /// -check path never touches `UserDefaults`.
    public func resolve() -> String {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        if let stored = defaults.string(forKey: Self.defaultsKey), !stored.isEmpty {
            cached = stored
            return stored
        }
        let minted = UUID().uuidString
        defaults.set(minted, forKey: Self.defaultsKey)
        cached = minted
        return minted
    }

    /// Drop the in-memory cache (tests only — the persisted value is untouched).
    public func resetCacheForTesting() {
        lock.lock()
        defer { lock.unlock() }
        cached = nil
    }

    // MARK: - App-group-aware resolution

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: PatchDeviceIDStore] = [:]

    /// Resolve the shared id for an optional app group, so a host app and its
    /// extensions report ONE identity.
    ///
    /// Falls back to `.standard` when no group is given, or when the group suite
    /// can't be opened (a wrong or unentitled identifier returns nil rather than
    /// trapping) — a wrong group degrades to today's per-target behaviour instead
    /// of crashing the host app.
    ///
    /// **Migration:** when the group suite has no id yet but `.standard` does,
    /// the existing `.standard` value is promoted into the group rather than
    /// minting a new one. An app that adds an app group in a later release keeps
    /// its device identity (and its rollout bucket) instead of churning.
    public static func resolve(appGroupIdentifier: String?) -> String {
        guard let group = appGroupIdentifier, !group.isEmpty else {
            return shared.resolve()
        }
        registryLock.lock()
        let store: PatchDeviceIDStore
        if let existing = registry[group] {
            store = existing
        } else if let suite = UserDefaults(suiteName: group) {
            if suite.string(forKey: defaultsKey)?.isEmpty ?? true,
               let inherited = UserDefaults.standard.string(forKey: defaultsKey),
               !inherited.isEmpty {
                suite.set(inherited, forKey: defaultsKey)
            }
            store = PatchDeviceIDStore(defaults: suite)
            registry[group] = store
        } else {
            store = shared
        }
        registryLock.unlock()
        return store.resolve()
    }

    /// Drop the app-group store registry (tests only).
    public static func resetRegistryForTesting() {
        registryLock.lock()
        registry.removeAll()
        registryLock.unlock()
    }
}

extension PatchConfiguration {
    /// The `device_id` actually sent on the wire.
    ///
    /// An explicit `deviceID` always wins; otherwise the persisted anonymous id,
    /// shared across the app group when one is configured. An empty string is
    /// treated as unset — it would collapse the rollout bucket exactly the way
    /// the old `"anon"` literal did.
    public var resolvedDeviceID: String {
        if let deviceID, !deviceID.isEmpty { return deviceID }
        return PatchDeviceIDStore.resolve(appGroupIdentifier: appGroupIdentifier)
    }
}
