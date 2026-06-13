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
// COORDINATION (engine-lowering agent): the engine vendors/shares THIS module.
// The two copies MUST declare the same `version`. The guest stamps the version
// into its emission envelope (`BodyEmission.schemaVersion`, see below); the host
// validates it on decode via `PatchViewIRSchema.check(_:)`. If the engine and
// SDK are versioned together (vendored from one source), the check is a belt-
// and-suspenders guard against a stale OTA module loaded by a newer host.
public enum PatchViewIRSchema {
    /// The current IR wire-format schema version. Engine + host MUST match.
    /// v1 = the initial productized schema (text/image/spacer/divider/color/
    /// shape primitives; vstack/hstack/zstack/group/forEach containers; button +
    /// the interactive controls toggle/slider/stepper/textField; the modifier set
    /// in `Modifier`; the `{root, coverage?}` BodyEmission + `{state, tree,
    /// coverage?}` DispatchResult envelopes).
    /// v2 = the MODIFIER-surface + unified `IRShapeStyle` styling vocabulary
    /// (foregroundStyle/background/fill/stroke/border/overlay/mask/shadow;
    /// offset/position/aspectRatio/clipped/layoutPriority/safeAreaInset/
    /// ignoresSafeArea/zIndex/containerRelativeFrame; rotation/scale/blur/
    /// brightness/contrast/saturation/grayscale/hueRotation/colorInvert/blendMode;
    /// the text-styling set; the built-in control-config style enums; the
    /// long-press/drag/magnify/rotate gestures; onAppear/onDisappear/onChange/
    /// task/onSubmit/onHover/sensoryFeedback lifecycle; animation/transition;
    /// the `IRValue.point` payload) — AND additive leaf-views (styledText/dateText/
    /// symbolImage/bundleImage/asyncImage/determinateProgress/gauge/link/shareLink/
    /// secureField/textEditor/labeledContent/menu/contextMenu, the generalized
    /// `label(title:icon:)`), containers (lazyV/HStack, lazyV/HGrid, grid/gridRow,
    /// groupBox, disclosureGroup, viewThatFits, controlGroup, tabView), and shape
    /// nodes (path, unevenRoundedRectangle, containerRelative). Purely additive: a
    /// v2 host decodes v1 guests; the bump gates a newer guest against an older host.
    /// v3 = the HOST-STATE tier (presentation/selection/navigation/focus/list-edit):
    /// the `sheet`/`sheetItem`/`fullScreenCover`/`popover`/`alert`/`confirmationDialog`/
    /// `navigationDestinationBool`/`toolbar`/`searchable`/`focused`/`onDelete`/`onMove`
    /// modifiers; the `picker`/`datePicker`/`colorPicker`/`navigationLink`/
    /// `navigationStackPath`/`boundDisclosureGroup`/`boundSection`/`boundTabView`/
    /// `editButton` node kinds; `Button(role:)`; and the `IRValue.array` payload (nav
    /// path / multi-select / index sets). Purely additive: a v3 host decodes v1/v2
    /// guests; the bump gates a newer guest against an older host. NOTE: `.button`
    /// gained a `role` field — a pre-v3 host can't decode a v3 button, which is why
    /// the schema gate refuses a v3 guest on an older host (correct: it would mis-route).

    public static let version = 3

    /// The oldest guest schema version this host's renderer can still decode.
    /// v1/v2 trees use only cases that still exist, so a v3 host renders them.
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
