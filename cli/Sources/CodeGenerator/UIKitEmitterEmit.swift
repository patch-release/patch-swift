// SPDX-License-Identifier: Apache-2.0

// UIKitEmitterEmit.swift — property folding, constraint resolution, literal
// translation, and the final `UI.`-tree emission for the cell lowering machine.
// =============================================================================

import SwiftSyntax
import ViewNodeIR

extension UIKitEmitter {

    // MARK: - Property folding (`view.prop = value`)

    mutating func applyProperty(viewName: String, prop: String, value: ExprSyntax) {
        guard let widget = views[viewName]?.widget else { return }
        switch prop {
        // common UIView props (ternary-aware where it adds value)
        case "backgroundColor":
            if let c = colorValueOrToken(value) { views[viewName]?.props.backgroundColor = c }
            else { bail("non-literal backgroundColor") }
        case "tintColor":
            if let c = colorValueOrToken(value) { views[viewName]?.props.tintColor = c }
            else { bail("non-literal tintColor") }
        case "alpha":
            if let g = numericValueOrToken(value) { views[viewName]?.props.alphaExpr = g } else { bail("non-literal alpha") }
        case "clipsToBounds", "isOpaque", "isUserInteractionEnabled":
            // clipsToBounds is modeled; isOpaque/isUserInteractionEnabled are accepted
            // (tolerated config a tree-render doesn't need to carry) — never a demote.
            if prop == "clipsToBounds" {
                if let g = boolValueExpr(value) { views[viewName]?.props.clipsToBoundsExpr = g } else { bail("non-literal clipsToBounds") }
            }
        case "isHidden":
            if let g = boolValueExpr(value) { views[viewName]?.props.isHiddenExpr = g } else { bail("non-literal isHidden") }
        case "accessibilityIdentifier":
            if let s = resolvePlainString(value) { views[viewName]?.props.accessibilityIdentifier = s } else { bail("non-literal accessibilityIdentifier") }
        case "cornerRadius" where widget != .label:
            // `v.cornerRadius` (the modern UIView shorthand isn't real, but some helpers
            // alias it; the canonical `v.layer.cornerRadius` is handled in applyLayerProperty).
            if let g = numericValueOrToken(value) { views[viewName]?.props.cornerRadiusExpr = g } else { bail("non-literal cornerRadius") }
        case "translatesAutoresizingMaskIntoConstraints":
            return  // handled in the assignment dispatcher; tolerate here too.

        // layer props
        case "layer":
            bail("bare `.layer` assignment")   // `v.layer = …` is nonsense; ignore-as-demote

        // UILabel payload
        case "text" where widget == .label:
            if let lit = stringValue(value) { views[viewName]?.props.text = lit } else { bail("non-input label text") }
        case "font" where widget == .label:
            if let f = fontValue(value) { views[viewName]?.props.font = f } else { bail("unmodelable font") }
        case "textColor" where widget == .label:
            if let c = colorValueOrToken(value) { views[viewName]?.props.textColor = c } else { bail("unmodelable textColor") }
        case "numberOfLines" where widget == .label:
            if let g = intValueExpr(value) { views[viewName]?.props.numberOfLinesExpr = g } else { bail("non-literal numberOfLines") }
        case "textAlignment" where widget == .label:
            if let a = Self.memberCaseName(value) { views[viewName]?.props.textAlignment = a } else { bail("unmodelable textAlignment") }
        case "adjustsFontForContentSizeCategory", "adjustsFontSizeToFitWidth",
             "lineBreakMode", "minimumScaleFactor", "allowsDefaultTighteningForTruncation",
             "baselineAdjustment", "showsExpansionTextWhenTruncated"
            where widget == .label:
            // Common UILabel tuning the IR doesn't carry per-node. Accepted (tolerated) so
            // a label that sets them still lowers — they don't change the lowered tree's
            // text/font/color, and dropping them is visually negligible vs demoting.
            return

        // UIImageView payload
        case "image" where widget == .imageView:
            if let img = Self.imageLiteral(value) { views[viewName]?.props.image = img } else { bail("unmodelable image") }
        case "contentMode" where widget == .imageView:
            if let m = Self.memberCaseName(value) { views[viewName]?.props.contentMode = m } else { bail("unmodelable contentMode") }

        // UIStackView payload
        case "axis" where widget == .stackView:
            if let a = Self.memberCaseName(value) { views[viewName]?.props.axis = a } else { bail("unmodelable axis") }
        case "spacing" where widget == .stackView:
            if let d = resolveDouble(value) { views[viewName]?.props.spacing = d }
            else if let g = numericValueOrToken(value) { views[viewName]?.props.spacingExpr = g }
            else { bail("non-literal spacing") }
        case "alignment" where widget == .stackView:
            if let a = Self.memberCaseName(value) { views[viewName]?.props.stackAlignment = a } else { bail("unmodelable stack alignment") }
        case "distribution" where widget == .stackView:
            if let d = Self.memberCaseName(value) { views[viewName]?.props.distribution = d } else { bail("unmodelable distribution") }
        case "isLayoutMarginsRelativeArrangement", "isBaselineRelativeArrangement"
            where widget == .stackView:
            // Stack tuning not carried per-node; accept (tolerate) rather than demote.
            return

        // UISwitch / UISlider / UITextField payload
        case "isOn" where widget == .switchControl:
            // R2-#91: bind `isOn` to a marshalled BOOL input (`mySwitch.isOn = model.isEnabled`)
            // or a model-driven ternary, exactly like slider `value` binds inputs — not just a
            // literal. A plain literal still folds to `isOn`; a bound/ternary form rides
            // `isOnExpr` (preferred at emit). Demotes only when neither resolves (a non-guest
            // value), matching the label/textField text channels.
            if let b = resolveBool(value) { views[viewName]?.props.isOn = b }
            else if let g = boolValueExpr(value) { views[viewName]?.props.isOnExpr = g }
            else if let g = guestBoolCondition(value) { views[viewName]?.props.isOnExpr = g }
            else { bail("non-literal/non-input isOn") }
        case "value" where widget == .slider:
            if let d = resolveDouble(value) { views[viewName]?.props.sliderValue = d }
            else if let g = numericValueOrToken(value) { views[viewName]?.props.sliderValueExpr = g }
            else { bail("non-literal slider value") }
        case "minimumValue" where widget == .slider:
            if let d = resolveDouble(value) { views[viewName]?.props.sliderMin = d }
            else if let g = numericValueOrToken(value) { views[viewName]?.props.sliderMinExpr = g }
            else { bail("non-literal minimumValue") }
        case "maximumValue" where widget == .slider:
            if let d = resolveDouble(value) { views[viewName]?.props.sliderMax = d }
            else if let g = numericValueOrToken(value) { views[viewName]?.props.sliderMaxExpr = g }
            else { bail("non-literal maximumValue") }
        case "text" where widget == .textField:
            if let lit = stringValue(value) { views[viewName]?.props.fieldText = lit } else { bail("non-input field text") }
        case "placeholder" where widget == .textField:
            if let lit = stringValue(value) { views[viewName]?.props.placeholder = lit } else { bail("non-input placeholder") }

        default:
            // `cornerRadius` is set via `v.layer.cornerRadius`, handled separately (the
            // lhs `v.layer.cornerRadius` is a nested member; see handleAssignment's
            // member-chain path). Any other prop we don't model → demote.
            bail("unmodelable property `.\(prop)` on \(viewName)")
        }
    }

    // MARK: - Root-view property folding (Lever A)

    /// Fold a property set on the CONTENT ROOT itself (`view.backgroundColor = …`, bare
    /// `backgroundColor = …`, `self.alpha = …`) onto `rootProps`. The root node is a
    /// `.view` container, so only container-level props apply; a tuning prop a tree-render
    /// doesn't need is TOLERATED (accepted, not a demote) so the construction still lowers.
    /// An unmodelable root prop DEMOTES (honest — never silently drop a visible change).
    mutating func applyRootProperty(prop: String, value: ExprSyntax) {
        switch prop {
        case "backgroundColor":
            if let c = colorValueOrToken(value) { rootProps.backgroundColor = c; rootPropsSet = true }
            else { bail("non-literal root backgroundColor") }
        case "tintColor":
            if let c = colorValueOrToken(value) { rootProps.tintColor = c; rootPropsSet = true }
            else { bail("non-literal root tintColor") }
        case "alpha":
            if let g = numericValueOrToken(value) { rootProps.alphaExpr = g; rootPropsSet = true }
            else { bail("non-literal root alpha") }
        case "clipsToBounds":
            if let g = boolValueExpr(value) { rootProps.clipsToBoundsExpr = g; rootPropsSet = true }
            else { bail("non-literal root clipsToBounds") }
        case "isHidden":
            if let g = boolValueExpr(value) { rootProps.isHiddenExpr = g; rootPropsSet = true }
            else { bail("non-literal root isHidden") }
        case "cornerRadius":
            if let g = numericValueOrToken(value) { rootProps.cornerRadiusExpr = g; rootPropsSet = true }
            else { bail("non-literal root cornerRadius") }
        case "accessibilityIdentifier":
            if let s = resolvePlainString(value) { rootProps.accessibilityIdentifier = s; rootPropsSet = true }
            else { bail("non-literal root accessibilityIdentifier") }
        case "translatesAutoresizingMaskIntoConstraints", "isOpaque", "isUserInteractionEnabled",
             "accessibilityLabel", "accessibilityTraits", "isAccessibilityElement",
             "preservesSuperviewLayoutMargins", "insetsLayoutMarginsFromSafeArea",
             "directionalLayoutMargins", "layoutMargins", "semanticContentAttribute",
             "restorationIdentifier", "tag", "autoresizingMask", "contentMode":
            // Root tuning / a11y / margin config the container node doesn't carry per-node:
            // tolerate (accept) — it doesn't change the lowered tree's visible structure.
            return
        default:
            bail("unmodelable root property `.\(prop)`")
        }
    }

    /// Fold a ROOT `.layer.<prop>` set (`view.layer.cornerRadius`, bare `layer.masksToBounds`)
    /// onto `rootProps`. cornerRadius/masksToBounds model; decorative layer props tolerate.
    mutating func applyRootLayerProperty(prop: String, value: ExprSyntax) {
        switch prop {
        case "cornerRadius":
            if let g = numericValueOrToken(value) { rootProps.cornerRadiusExpr = g; rootPropsSet = true }
            else { bail("non-literal root layer cornerRadius") }
        case "masksToBounds":
            if let g = boolValueExpr(value) { rootProps.clipsToBoundsExpr = g; rootPropsSet = true }
            else { bail("non-literal root layer masksToBounds") }
        case "borderWidth", "borderColor", "shadowOpacity", "shadowRadius",
             "shadowColor", "shadowOffset", "cornerCurve", "maskedCorners":
            return  // decorative; tolerate (mirrors the local-view layer path).
        default:
            bail("unmodelable root layer property `.\(prop)`")
        }
    }

    // A nested `v.layer.cornerRadius = r` arrives with lhs base = `v.layer`. Detect it
    // by re-parsing the member chain. Called from the assignment dispatcher for a
    // 2-level member lhs.
    mutating func applyLayerProperty(viewName: String, prop: String, value: ExprSyntax) {
        guard views[viewName] != nil else { bail("layer set on unknown view"); return }
        switch prop {
        case "cornerRadius":
            if let g = numericValueOrToken(value) { views[viewName]?.props.cornerRadiusExpr = g }
            else { bail("non-literal layer cornerRadius") }
        case "masksToBounds":
            if let g = boolValueExpr(value) { views[viewName]?.props.clipsToBoundsExpr = g }
            else { bail("non-literal layer masksToBounds") }
        case "borderWidth", "borderColor", "shadowOpacity", "shadowRadius",
             "shadowColor", "shadowOffset", "cornerCurve", "maskedCorners":
            // Common decorative layer props the per-node IR doesn't carry. Accept
            // (tolerate) rather than demote — the lowered tree still renders, just
            // without the (visually minor) border/shadow. NEVER drops a subview.
            return
        default:
            bail("unmodelable layer property `.\(prop)`")
        }
    }

    /// `button.titleLabel?.font = …` / `.textColor` / `.numberOfLines` — fold onto the
    /// button leaf (font → button font, textColor → title color). A `titleLabel` prop we
    /// don't model is tolerated (accepted, not a demote) — the button still lowers.
    mutating func applyButtonTitleLabelProperty(viewName: String, prop: String, value: ExprSyntax) {
        guard views[viewName]?.widget == .button else { bail("titleLabel set on non-button"); return }
        switch prop {
        case "font":
            if let f = fontValue(value) { views[viewName]?.props.buttonFont = f } else { bail("unmodelable button font") }
        case "textColor":
            if let c = colorValueOrToken(value) { views[viewName]?.props.buttonTitleColor = c } else { bail("unmodelable button title color") }
        default:
            // numberOfLines / lineBreakMode / textAlignment on a button's titleLabel: the
            // button leaf doesn't carry them per-node — tolerate (accept) rather than demote.
            return
        }
    }

    // MARK: - Event / action attach

    mutating func recordAction(_ id: String) {
        if !actionIDs.contains(id) { actionIDs.append(id) }
    }

    mutating func attachEvent(viewName: String, actionID: String) {
        guard var build = views[viewName] else { return }
        switch build.widget {
        case .button: build.props.buttonAction = actionID
        case .switchControl: build.props.switchEvent = actionID
        case .slider: build.props.sliderEvent = actionID
        case .textField: build.props.fieldEvent = actionID
        default: break   // a target on a plain view isn't modeled; ignore (no demote).
        }
        views[viewName] = build
    }

    // MARK: - Helper inlining

    mutating func walkInline(_ statements: CodeBlockItemListSyntax) {
        // A helper body is the SAME recognized grammar as the top-level method (incl.
        // model-driven conditionals); delegate to the shared `walkBlock` so it lowers
        // identically (a helper that `if`-gates a subview lowers too).
        walkBlock(statements)
    }

    // MARK: - Tree emission (walk parent→child graph from the root)

    mutating func emitNode(name: String, indent: Int) -> String {
        guard let build = views[name] else { return "UI.slot(id: \"missing\")" }
        let pad = String(repeating: "    ", count: indent)
        let childPad = String(repeating: "    ", count: indent + 1)

        // Children in declaration order (initialArranged seeded the list). Built with a
        // loop (not `.map`) so the recursive call can mutate `self` (slot recording).
        let kids = childrenStore[name] ?? []
        var kidExprs: [String] = []
        for kid in kids { kidExprs.append(emitNode(name: kid, indent: indent + 1)) }

        var base: String
        switch build.widget {
        case .label:
            base = "UI.label(\(build.props.text?.guest ?? "\"\"")"
                + optArg("font", build.props.font?.guest)
                + optArg("textColor", build.props.textColor?.guest)
                + optArg("numberOfLines", build.props.numberOfLinesExpr)
                + optArg("alignment", build.props.textAlignment.map { ".\($0)" })
                + ")"
        case .button:
            let action = build.props.buttonAction ?? ""
            base = "UI.button(\(build.props.buttonTitle?.guest ?? "\"\"")"
                + optArg("titleColor", build.props.buttonTitleColor?.guest)
                + optArg("font", build.props.buttonFont?.guest)
                + ", action: \"\(action)\")"
        case .imageView:
            base = "UI.image("
                + (build.props.image?.guest ?? "systemName: \"\"")
                + optArg("tintColor", build.props.tintColor?.guest)
                + optArg("contentMode", build.props.contentMode.map { ".\($0)" })
                + ")"
        case .stackView:
            let axis = build.props.axis ?? "vertical"
            base = "UI.stack(axis: .\(axis)"
                + optArg("spacing", build.props.spacingExpr ?? build.props.spacing.map(Self.numLit))
                + optArg("alignment", build.props.stackAlignment.map { ".\($0)" })
                + optArg("distribution", build.props.distribution.map { ".\($0)" })
                + ", arranged: [\n"
                + kidExprs.map { childPad + $0 }.joined(separator: ",\n")
                + (kidExprs.isEmpty ? "" : "\n\(pad)") + "])"
        case .view:
            base = "UI.container([\n"
                + kidExprs.map { childPad + $0 }.joined(separator: ",\n")
                + (kidExprs.isEmpty ? "" : "\n\(pad)") + "])"
        case .switchControl:
            // A model-bound / ternary `isOn` (R2-#91) rides the guest expr; else the folded
            // literal (the established path, byte-identical when no bound value was set).
            let isOnArg = build.props.isOnExpr ?? "\(build.props.isOn ?? false)"
            base = "UI.switchControl(isOn: \(isOnArg), event: \"\(build.props.switchEvent ?? "")\")"
        case .slider:
            base = "UI.slider(value: \(build.props.sliderValueExpr ?? Self.numLit(build.props.sliderValue ?? 0))"
                + ", min: \(build.props.sliderMinExpr ?? Self.numLit(build.props.sliderMin ?? 0))"
                + ", max: \(build.props.sliderMaxExpr ?? Self.numLit(build.props.sliderMax ?? 1))"
                + ", event: \"\(build.props.sliderEvent ?? "")\")"
        case .textField:
            base = "UI.textField(text: \(build.props.fieldText?.guest ?? "\"\"")"
                + ", placeholder: \(build.props.placeholder?.guest ?? "\"\"")"
                + ", event: \"\(build.props.fieldEvent ?? "")\")"
        case .custom(let typeName, let source, let slotable):
            // A non-lowerable subview → a native customSlot. `slotable` was computed at
            // registration (real AST in hand). The id is content-stable (FNV-1a over the
            // source), so the engine (push) and the thunk generator (build) agree.
            let id = "uislot_" + Self.stableHash64(source)
            recordSlot(id: id, source: source, slotable: slotable, label: typeName)
            return "UI.slot(id: \"\(id)\", label: \"\(Self.safeLabel(typeName))\")"
        }

        // Apply the chainable view props (id + the common ones the leaf builders don't
        // already carry) + the constraints.
        var chain = base
        if name.hasPrefix("__patch") == false { chain += ".id(\"\(name)\")" }
        if let c = build.props.backgroundColor?.guest { chain += ".background(\(c))" }
        // Numeric/bool props: a guest-EXPRESSION override (a model-driven ternary) wins;
        // else the folded literal (the established literal path, byte-identical).
        if let g = build.props.cornerRadiusExpr { chain += ".cornerRadius(\(g))" }
        else if let r = build.props.cornerRadius { chain += ".cornerRadius(\(Self.numLit(r)))" }
        if let g = build.props.clipsToBoundsExpr { chain += ".clipsToBounds(\(g))" }
        else if let b = build.props.clipsToBounds { chain += ".clipsToBounds(\(b))" }
        if let g = build.props.alphaExpr { chain += ".alpha(\(g))" }
        else if let a = build.props.alpha { chain += ".alpha(\(Self.numLit(a)))" }
        if let g = build.props.isHiddenExpr { chain += ".hidden(\(g))" }
        else if let h = build.props.isHidden { chain += ".hidden(\(h))" }
        // tintColor on a non-imageView leaf (imageView carries it in its builder).
        if build.widget != .imageView, let t = build.props.tintColor?.guest { chain += ".tint(\(t))" }
        if let aid = build.props.accessibilityIdentifier { chain += ".accessibilityIdentifier(\"\(Self.escape(aid))\")" }
        for c in build.constraints { chain += ".\(Self.constraintCall(c))" }
        return chain
    }

    mutating func recordSlot(id: String, source: String, slotable: Bool, label: String) {
        guard !customSlots.contains(where: { $0.id == id }) else { return }
        customSlots.append(.init(id: id, source: source, slotable: slotable, label: label))
    }

    private func optArg(_ label: String, _ value: String?) -> String {
        guard let value else { return "" }
        return ", \(label): \(value)"
    }

    static func safeLabel(_ s: String) -> String {
        String(s.replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "\n", with: " ").prefix(60))
    }
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// A numeric literal printed without a trailing `.0` ambiguity issue (the
    /// builder takes `Double`; `1` and `1.0` both fine, but keep it readable).
    static func numLit(_ d: Double) -> String {
        if d == d.rounded() && abs(d) < 1e15 { return String(Int(d)) }
        return String(d)
    }

    /// Full-width FNV-1a content hash (stable across processes/platforms), matching
    /// the SwiftUI emitter's `stableHash64` so engine + thunk agree on slot ids.
    static func stableHash64(_ s: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { hash ^= UInt64(b); hash = hash &* 0x100000001b3 }
        return String(hash, radix: 16)
    }
}

