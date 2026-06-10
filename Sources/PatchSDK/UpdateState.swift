import Foundation

// MARK: - UpdateInfo

/// A summary of an available OTA update, returned by `Patch.checkForUpdate()`
/// (the EAS-Expo-Updates-style imperative API). It describes availability only —
/// nothing is downloaded or applied until the developer calls `fetchUpdate()` /
/// `reloadAsync()`. `isMandatory` surfaces the backend's `response.mandatory`
/// flag (spec §5) so the host app can decide whether to block the UI.
public struct UpdateInfo: Sendable, Equatable {
    /// The version string of the available module (`response.version`).
    public let version: String
    /// Optional human-readable release notes (`response.release_notes`).
    public let releaseNotes: String?
    /// Whether the backend marked this update mandatory (`response.mandatory`).
    public let isMandatory: Bool
    /// Advertised size in bytes of the new module (`response.size`, 0 if absent).
    public let sizeBytes: Int

    public init(version: String, releaseNotes: String?, isMandatory: Bool, sizeBytes: Int) {
        self.version = version
        self.releaseNotes = releaseNotes
        self.isMandatory = isMandatory
        self.sizeBytes = sizeBytes
    }

    /// Build from an `UpdateCheckResponse`. Returns nil when there is no update.
    init?(response: UpdateCheckResponse) {
        guard response.has_update, let version = response.version else { return nil }
        self.version = version
        self.releaseNotes = response.release_notes
        self.isMandatory = response.mandatory
        self.sizeBytes = response.size ?? 0
    }
}

// MARK: - PatchUpdateState

/// The lifecycle of the imperative update flow, observable from SwiftUI.
///
/// Drives a "Update available → Download now → Reload" UI without the developer
/// having to track booleans by hand. Published on `Patch.shared.updateState`
/// (an `@MainActor` `ObservableObject`). `@MainActor` + `ObservableObject` is
/// used (rather than the newer `@Observable` macro) so the SDK keeps its iOS 16
/// deployment floor — `@Observable` requires iOS 17+.
public enum PatchUpdateState: Sendable, Equatable {
    /// No check has run yet (or state was reset).
    case idle
    /// A `/modules/check` request is in flight.
    case checking
    /// An update is available but not yet downloaded.
    case available(UpdateInfo)
    /// The available update is downloading; payload is fractional progress 0…1.
    case downloading(Double)
    /// The update has been fetched + verified + staged; call `reloadAsync()`.
    case readyToReload
    /// The check completed and the app is already on the latest module.
    case upToDate
    /// The last operation failed; payload is a human-readable message.
    case failed(String)
}

/// `@MainActor` observable that publishes `PatchUpdateState` for SwiftUI.
///
/// SwiftUI views observe `Patch.shared.updateState` (an instance of this type)
/// with `@ObservedObject` / `@StateObject`. The SDK mutates `state` from the
/// main actor as the imperative flow progresses, so views re-render
/// automatically. The current `UpdateInfo` (if any) is mirrored on `available`
/// for convenient binding.
@MainActor
public final class PatchUpdateStateObservable: ObservableObject {
    /// The current phase of the update flow. Bind to this in SwiftUI.
    @Published public private(set) var state: PatchUpdateState = .idle

    /// The most recently discovered available update, if any (mirrors the
    /// `.available` / `.readyToReload` payload for convenient access).
    @Published public private(set) var available: UpdateInfo?

    /// `nonisolated` so the owning `Patch` can construct it from its nonisolated
    /// `init()`. Only sets the two stored defaults; no observers exist yet, so
    /// this is safe off the main actor. All later mutation goes through `set`,
    /// which the SDK hops to the main actor for.
    public nonisolated init() {}

    /// Set the published state (and keep `available` in sync). Internal — the
    /// SDK drives this; the host app only reads.
    func set(_ new: PatchUpdateState) {
        state = new
        switch new {
        case .available(let info):
            available = info
        case .idle, .upToDate, .failed:
            available = nil
        case .checking, .downloading, .readyToReload:
            break  // keep the last-known available info during fetch/reload.
        }
    }
}
