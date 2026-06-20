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
    /// v4 = DESIGN-SYSTEM TOKENS: `ColorRef.hostToken(id)` (a custom color token —
    /// `Theme.Colors.ink` — supplied natively by the build-time thunk, applied to
    /// `foregroundStyle`/`background`/`tint`/`fill`/`stroke`/`shadow`) and the
    /// `Modifier.fontToken(id)` case (a custom `Font` token — `Theme.Font.body(...)`).
    /// Purely additive: a v4 host decodes v1/v2/v3 guests (older trees never carry the
    /// new cases); the bump gates a newer guest against an older host.
    /// v5 = SCROLL & LAYOUT modifiers: the `scrollDisabled`/`scrollIndicators`/
    /// `scrollTargetBehavior`/`scrollTargetLayout`/`scrollBounceBehavior`/
    /// `contentMargins`/`safeAreaPadding` `Modifier` cases (the high-value scroll/
    /// layout modifiers that previously slotted; each carries pure data the renderer
    /// reapplies as the real SwiftUI modifier, OS-floor-guarded). Purely additive: a
    /// v5 host decodes v1–v4 guests (older trees never carry the new cases); the bump
    /// gates a newer guest (one that uses a scroll/layout modifier) against an older
    /// host that can't decode the new case (it would collapse the whole view, so the
    /// gate correctly refuses the module → native fallback).
    /// v6 = VISIBILITY / CHROME / DECLARATIVE-EFFECT modifiers: the `hidden`/
    /// `labelsHidden`/`labelsVisibility`/`menuIndicator`/`menuOrder`/
    /// `persistentSystemOverlays`/`headerProminence`/`badgeProminence`/`listItemTint`/
    /// `listRowSeparatorTint`/`listSectionSeparatorTint`/`containerShape`/
    /// `compositingGroup`/`geometryGroup`/`drawingGroup`/`colorMultiply`/
    /// `luminanceToAlpha`/`contentTransition`/`textSelection`/`allowsTightening`/
    /// `flipsForRightToLeftLayoutDirection`/`invalidatableContent`/
    /// `lineLimitReservesSpace`/`defaultScrollAnchor`/`selectionDisabled`/
    /// `moveDisabled`/`deleteDisabled` `Modifier` cases (declarative enum/bool/scalar/
    /// ColorRef/ShapeKind config that previously slotted; the renderer reapplies the
    /// real SwiftUI modifier, OS-floor-guarded). Purely additive: a v6 host decodes
    /// v1–v5 guests (older trees never carry the new cases); the bump gates a newer
    /// guest (one using a v6 modifier) against an older host that can't decode the new
    /// case (it would collapse the whole view, so the gate correctly refuses → native).
    /// v7 = ACCESSIBILITY / HELP / TEXT-INPUT / PRESENTATION-config modifiers: the
    /// `help`/`accessibilityIdentifier`/`accessibilitySortPriority`/
    /// `accessibilityRespondsToUserInteraction`/`accessibilityIgnoresInvertColors`/
    /// `privacySensitive`/`speechAlwaysIncludesPunctuation`/`speechSpellsOutCharacters`/
    /// `speechAnnouncementsQueued`/`speechAdjustedPitch`/`scrollDismissesKeyboard`/
    /// `fontWidth`/`textScale`/`symbolEffectsRemoved`/`findDisabled`/`replaceDisabled`/
    /// `statusBarHidden`/`contentShape`/`coordinateSpaceNamed`/`interactiveDismissDisabled`/
    /// `presentationCornerRadius`/`presentationContentInteraction`/
    /// `presentationCompactAdaptation` `Modifier` cases (declarative string/bool/scalar/
    /// ShapeKind config that previously slotted; the renderer reapplies the real SwiftUI
    /// modifier, OS-floor-guarded). Purely additive: a v7 host decodes v1–v6 guests (older
    /// trees never carry the new cases); the bump gates a newer guest (one using a v7
    /// modifier) against an older host that can't decode the new case (it would collapse
    /// the whole view, so the gate correctly refuses → native fallback).
    /// v8 = PER-ROW INDEXED NATIVE-ACTION SLOTS: the `indexedForEachSlot(id:countKey:label:)`
    /// `NodeKind` case — a `ForEach` over a BODY-LOCAL collection the guest can't
    /// reconstruct, whose rows are a custom child view with a PER-ROW native action
    /// closure (`AccountChip(...) { schedule.selectedOwnerId = owner.id }`). The
    /// build-time thunk natively evaluates the body-local collection and supplies a
    /// per-row factory `(Int) -> AnyView` (closing over `self`); the host reads the row
    /// count from a reserved `__rowcount_<id>` input (rides the input JSON, like
    /// `__numtok_*`) and reconstitutes `count` rows. Purely additive: a v8 host decodes
    /// v1–v7 guests (older trees never carry the new case); the bump gates a newer guest
    /// (one using an indexed-row slot) against an older host that can't decode the new
    /// case (it would collapse the whole view, so the gate correctly refuses → native).

    // v9 = REACTIVE VIEW-MODEL COLLECTION MARSHALLING capability: a view whose `ForEach(vm.items)`
    // marshals a reactive `@ObservedObject`/`@StateObject` model's collection requires the SDK's
    // reactive-`extract` path (PatchInstanceInputs marshals the held object as a nested `{"vm":…}`).
    // An SDK at v8 lacks `extract` for that input, so the guest would read an empty collection and
    // render ZERO rows. Purely additive (a v9 host decodes v1–v8 guests); the per-view manifest
    // `minVersion` gates a reactive-marshalling view to v9 so an older host DEMOTES it to native
    // (the dev's real `ForEach` then renders) instead of empty-rendering.
    //
    // v9 ALSO adds the `actionSlotButton(id:role:label:)` `NodeKind` case — a Button inside an
    // actions-list builder (`.swipeActions`/`.toolbar`/`.alert`/`Menu`/`.contextMenu`) whose action
    // is a NATIVE method call: the LABEL + `role` lower (OTA-patchable) while the ACTION is a
    // NATIVE SLOT closure (`() -> Void`, closing over `self`) the thunk's `__patchActionSlots()`
    // supplies by id and the renderer wires to the Button. Purely additive (a v9 host decodes
    // v1–v8 guests, which never carry the new case); a guest USING an actionSlotButton stamps the
    // per-view manifest `minVersion` to 9 so an older host (without the new case → would collapse
    // the whole view on decode) DEMOTES it to native instead. An UNCOVERED slot id demotes the
    // whole view at runtime (mirrors the opaque-leaf / row-slot demote-safety) — never a dead button.

    // v10 = NATIVE EFFECT-MODIFIER SLOTS: the `Modifier.nativeEffectSlot(id)` case — an
    // undispatchable EFFECT modifier (`.task`/`.onAppear`/`.refreshable`/`.onSubmit`/`.onTapGesture`/
    // `.gesture`/`.onLongPressGesture`/`.onDisappear`) whose closure runs a NATIVE side-effect the
    // guest can't re-run in WASM, but whose presence should NOT demote the rest of the view. The
    // MODIFIED SUBTREE lowers to WASM normally (so editing unrelated text inside the view ships OTA);
    // the modifier carries only a content-stable id, and the build-time thunk's `__patchEffectSlots()`
    // supplies `[id: (AnyView) -> AnyView]` applying the REAL modifier expression (over `self`) to its
    // content. The renderer applies that closure to the rendered subtree; the native effect runs
    // exactly as before, and an instance-state mutation re-renders the guest via the existing
    // Observation + re-marshal path. Purely additive (a v10 host decodes v1–v9 guests, which never
    // carry the new case); a guest USING a `nativeEffectSlot` stamps the per-view manifest `minVersion`
    // to 10 so an older host (whose synthesized `Modifier` decoder would THROW on the unknown case →
    // collapse the whole view on decode) DEMOTES it to native instead. An UNCOVERED slot id demotes
    // the whole view at runtime (mirrors the opaque-leaf / action-slot demote-safety) — never strips a
    // body whose effect it can't supply (which would silently re-show the OLD native view).
    //
    // v11 = FAITHFUL `.animation(_:value:)` RENDERING: the `Modifier.animation(_, valueKey:)` case
    // already existed (since v2), but the renderer NO-OPPED it — a host applied the value change
    // INSTANTLY (no animation) while natively it animates. So the engine MARKED an `.animation(value:)`
    // view UNDISPATCHABLE → it demoted to native (BUG #62). The host now reconstitutes the real
    // `Animation` (via `Renderer.animation(_:)`) AND watches the watched `@State`'s CURRENT scalar
    // (resolved from the marshalled input JSON into an `AnyHashable`, plumbed via
    // `RenderContext.animationValues`) as the `Equatable` trigger — a change to that value across
    // renders fires the implicit animation, matching native. NO new wire case (the `.animation`
    // Modifier is unchanged); the bump is a per-view RENDER-FIDELITY gate: a guest that USES
    // `.animation(_:value:)` stamps the per-view manifest `minVersion` to 11 so an OLDER host (whose
    // renderer would still NO-OP the animation → render the value change instantly, a SILENTLY
    // degraded effect) DEMOTES the view to native (where the real implicit animation runs) instead.
    // DEMOTE-SAFE at render time: an unresolvable trigger scalar degrades to a CONSTANT value (the
    // curve still attaches; the view stays patched; it just never re-triggers) — never a wrong render
    // or a crash. Purely additive: a v11 host decodes v1–v10 guests unchanged.
    public static let version = 11

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
