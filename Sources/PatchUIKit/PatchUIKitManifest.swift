// PatchUIKitManifest.swift — the engine-emitted UIKit cell manifest + its decode.
// =============================================================================
// Kept UIKit-FREE (pure Foundation) and OUTSIDE any `#if canImport(UIKit)` so it
// compiles + is unit-tested on the headless macOS CI host too — the manifest decode
// + schema gate are the platform-independent core of the cell-patching decision.
// (The actual `renderUIKit` install in `UIKitPatchHost.swift` is UIKit-guarded.)

import Foundation

/// The engine-emitted manifest describing which lowered cell-construction exports the
/// active module ships, keyed by the cell's (sanitized) type name. Decoded from the
/// module's `patch_uikit_manifest` export (a compile-time JSON literal in the guest).
public struct PatchUIKitManifest: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        /// The sanitized cell type name — matches the literal the generated thunk
        /// passes to `installPatchedCell`.
        public let type: String
        /// The `uikit_configure__<Cell>` export building this cell's tree.
        public let export: String
        /// True when the construction lowered with NO unslotable leaf + no
        /// unmarshalled input — the only case the SDK auto-routes.
        public let thunkSafe: Bool
        public init(type: String, export: String, thunkSafe: Bool) {
            self.type = type; self.export = export; self.thunkSafe = thunkSafe
        }
    }
    public let schemaVersion: Int
    public let cells: [Entry]
    public init(schemaVersion: Int, cells: [Entry]) {
        self.schemaVersion = schemaVersion; self.cells = cells
    }

    /// The guest export name (packed `(ptr,len) -> i64` ABI; input ignored).
    public static let exportName = "patch_uikit_manifest"
    /// The schema version this SDK understands (matches the engine's
    /// `UIKitGuestEmitter.manifestSchemaVersion`).
    public static let supportedSchemaVersion = 1

    /// Decode + schema-gate a manifest's JSON bytes into a `[type: Entry]` map. A
    /// manifest stamped with a NEWER schema than this SDK understands yields an empty
    /// map (refuse to route rather than mis-decode). Shared by the registry + tests.
    public static func decodeEntries(_ jsonBytes: [UInt8]) -> [String: Entry] {
        guard let manifest = try? JSONDecoder().decode(PatchUIKitManifest.self,
                                                       from: Data(jsonBytes)),
              manifest.schemaVersion <= supportedSchemaVersion else {
            return [:]
        }
        var out: [String: Entry] = [:]
        for entry in manifest.cells { out[entry.type] = entry }
        return out
    }
}
