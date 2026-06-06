// Schema.swift — the ViewNode IR wire-format schema VERSION contract.
// =====================================================================
// `PatchViewIR` is the SINGLE shared IR between the WASM *guest* (which the
// engine-lowering pipeline emits — it builds + serializes a `ViewNode` tree
// inside the sandbox) and the native *host* renderer in `PatchRender` (which
// reconstitutes REAL SwiftUI). For a shipped OTA module and the host SDK that
// renders it to stay compatible, BOTH ends must agree on the IR's wire shape.
//
// This file is that agreement, made explicit so a mismatch is a checked error
// rather than a silent mis-render:
//
//   * `PatchViewIRSchema.version` is the integer schema version. BUMP IT in this
//     file (and in the engine's copy of the IR) whenever the JSON wire shape of
//     `ViewNode` / `BodyEmission` / `DispatchResult` changes incompatibly (a new
//     `NodeKind`/`Modifier` case, a renamed/removed field, a changed payload
//     encoding). Purely additive host-tolerant changes do NOT require a bump,
//     but bumping is always safe.
//
//   * `PatchViewIRSchema.minSupportedVersion` is the OLDEST guest schema this
//     host can still decode. The host accepts any guest version in
//     `minSupportedVersion ... version`.
//
// The engine vendors/shares THIS module, so the two copies MUST declare the
// same `version`. The guest stamps the version
// into its emission envelope (`BodyEmission.schemaVersion`, see below); the host
// validates it on decode via `PatchViewIRSchema.check(_:)`. If the engine and
// SDK are versioned together (vendored from one source), the check is a belt-
// and-suspenders guard against a stale OTA module loaded by a newer host.
public enum PatchViewIRSchema {
    /// The current IR wire-format schema version. Engine + host MUST match.
    /// v1 = the initial schema (text/image/spacer/divider/color/
    /// shape primitives; vstack/hstack/zstack/group/forEach containers; button +
    /// the interactive controls toggle/slider/stepper/textField; the modifier set
    /// in `Modifier`; the `{root, coverage?}` BodyEmission + `{state, tree,
    /// coverage?}` DispatchResult envelopes).
    public static let version = 1

    /// The oldest guest schema version this host's renderer can still decode.
    public static let minSupportedVersion = 1

    /// Whether a guest-stamped schema version is renderable by this host.
    public static func isSupported(_ guestVersion: Int) -> Bool {
        guestVersion >= minSupportedVersion && guestVersion <= version
    }

    /// A schema mismatch surfaced when a host tries to render a guest tree whose
    /// declared schema version it cannot decode.
    public struct Mismatch: Error, CustomStringConvertible, Equatable {
        public let guestVersion: Int
        public var hostVersion: Int { PatchViewIRSchema.version }
        public var hostMinSupported: Int { PatchViewIRSchema.minSupportedVersion }
        public init(guestVersion: Int) { self.guestVersion = guestVersion }
        public var description: String {
            "ViewNode IR schema mismatch: guest emitted v\(guestVersion), "
            + "host supports v\(hostMinSupported)...v\(hostVersion). "
            + "Update the host SDK (or re-lower the module with a matching engine)."
        }
    }

    /// Throw `Mismatch` if `guestVersion` is outside the supported range. A `nil`
    /// guest version means "unstamped" — treated as the current version (the
    /// pre-stamping wire shape is the v1 shape), so old fixtures still render.
    public static func check(_ guestVersion: Int?) throws {
        guard let v = guestVersion else { return }
        if !isSupported(v) { throw Mismatch(guestVersion: v) }
    }
}
