// SPDX-License-Identifier: Apache-2.0

// UIKitEmitterLiterals.swift — translate UIKit literal expressions to guest
// `UIKitNode`/shared-IR builder expressions, + the widget type map.
// =============================================================================
// Folds the right-hand sides of property sets into the IR value vocabulary:
//   * a string literal / a marshalled model field → a guest `String` expression,
//   * `.systemFont(ofSize:weight:)` / `.boldSystemFont(ofSize:)` / `.preferredFont`
//     → an `IRFont(...)` builder expr,
//   * `UIImage(systemName:)` / `UIImage(named:)` → an `IRImageRef`,
//   * `.systemBlue` / `UIColor(red:green:blue:alpha:)` / `.label` → a `ColorRef`,
//   * `.center`/`.fill`/`.vertical`/… → the case name (used as `.center`, etc.).
// A form we can't translate returns nil → the caller `bail`s (whole-method demote).

import Foundation
import SwiftSyntax
import ViewNodeIR

extension UIKitEmitter {

    // MARK: - Widget type map

    /// The lowerable widget for a UIKit type name, or nil (a custom subview → slot).
    static func widget(forType type: String) -> Widget? {
        switch type {
        case "UILabel": return .label
        case "UIButton": return .button
        case "UIImageView": return .imageView
        case "UIStackView": return .stackView
        case "UIView": return .view
        case "UISwitch": return .switchControl
        case "UISlider": return .slider
        case "UITextField": return .textField
        default: return nil
        }
    }

    // MARK: - String / input expressions

    /// A guest STRING expression for a label/title/text/placeholder value:
    ///   * `"literal"` → the literal (verbatim, re-escaped),
    ///   * `model.title` / a bare input name → the marshalled input identifier
    ///     (`model.title` is flattened to the bound `let title` the guest scans),
    ///   * `"\(model.first) \(model.last)"` interpolation of inputs → a `+`-built
    ///     guest String (Embedded-Swift-safe — no String interpolation tables),
    /// else nil (demote — a non-input dynamic string can't ride WASM faithfully).
    mutating func literalString(_ expr: ExprSyntax) -> ExprLit? {
        // A plain string literal (no interpolation).
        if let s = expr.as(StringLiteralExprSyntax.self) {
            if s.segments.count == 1, let seg = s.segments.first?.as(StringSegmentSyntax.self) {
                return ExprLit(guest: "\"\(Self.escape(seg.content.text))\"")
            }
            // Interpolated: build with `+` so the guest is Embedded-clean.
            return interpolatedString(s)
        }
        // A member/identifier reading a marshalled input (`model.title`, `title`).
        if let g = inputReadExpr(expr) { return ExprLit(guest: g) }
        return nil
    }

    /// Translate `"\(a) - \(b)"` to `a + " - " + b` over the marshalled inputs. A
    /// segment that isn't a literal or an input read aborts (nil → demote).
    private mutating func interpolatedString(_ s: StringLiteralExprSyntax) -> ExprLit? {
        var parts: [String] = []
        for seg in s.segments {
            if let str = seg.as(StringSegmentSyntax.self) {
                if str.content.text.isEmpty { continue }
                parts.append("\"\(Self.escape(str.content.text))\"")
            } else if let expr = seg.as(ExpressionSegmentSyntax.self) {
                guard let arg = expr.expressions.first?.expression,
                      let g = inputReadExpr(arg) else { return nil }
                parts.append(g)
            }
        }
        guard !parts.isEmpty else { return ExprLit(guest: "\"\"") }
        return ExprLit(guest: parts.joined(separator: " + "))
    }

    /// If `expr` reads one of the marshalled inputs, the guest expression for it (the
    /// `model.` prefix is stripped to the flat bound name). Records the read. Returns
    /// nil for anything that isn't a known input.
    mutating func inputReadExpr(_ expr: ExprSyntax) -> String? {
        let raw = expr.trimmedDescription
        // Exact match against a declared input name (`model.title`, or a stored prop).
        if let inp = inputs.first(where: { $0.name == raw }) {
            referencedInputs.insert(inp.name)
            return Self.flatInputName(inp.name)
        }
        // A bare identifier matching the flattened tail of a `model.x` input.
        if let inp = inputs.first(where: { Self.flatInputName($0.name) == raw }) {
            referencedInputs.insert(inp.name)
            return raw
        }
        return nil
    }

    /// `model.title` → `title` (the flat name the guest binds); a bare name unchanged.
    static func flatInputName(_ name: String) -> String {
        if let dot = name.firstIndex(of: ".") { return String(name[name.index(after: dot)...]) }
        return name
    }

    /// A plain (non-input) string literal's content, or nil. Used for
    /// `accessibilityIdentifier` (always a literal, never marshalled).
    static func plainStringLiteral(_ expr: ExprSyntax) -> String? {
        guard let s = expr.as(StringLiteralExprSyntax.self), s.segments.count == 1,
              let seg = s.segments.first?.as(StringSegmentSyntax.self) else { return nil }
        return seg.content.text
    }

    // MARK: - Namespace-constant resolution (Lever B)

    /// The dotted access path of a member-access / bare-identifier expression
    /// (`UX.spacing` → "UX.spacing", `Layout.UX.spacing` → "Layout.UX.spacing",
    /// `spacing` → "spacing"), or nil for anything else (a call, an index, …). Used to
    /// look the expression up in the collected namespace constants.
    static func constantAccessPath(_ expr: ExprSyntax) -> String? {
        if let ref = expr.as(DeclReferenceExprSyntax.self) { return ref.baseName.text }
        if let m = expr.as(MemberAccessExprSyntax.self), let base = m.base {
            guard let basePath = constantAccessPath(base) else { return nil }
            return "\(basePath).\(m.declName.baseName.text)"
        }
        return nil
    }

    /// A `Double` from a numeric literal OR a resolved numeric namespace constant
    /// (`UX.spacing` → 8). The instance form (sees `namespaceConstants`); the static
    /// `doubleLiteral` stays the pure-literal path. A negative `-UX.spacing` resolves too.
    mutating func resolveDouble(_ expr: ExprSyntax) -> Double? {
        if let d = Self.doubleLiteral(expr) { return d }
        if let path = Self.constantAccessPath(expr), case .number(let d)? = namespaceConstants[path] {
            return d
        }
        // `-UX.spacing`.
        if let prefix = expr.as(PrefixOperatorExprSyntax.self), prefix.operator.text == "-",
           let d = resolveDouble(prefix.expression) { return -d }
        return nil
    }

    /// An `Int` from an integer literal OR a resolved numeric namespace constant.
    mutating func resolveInt(_ expr: ExprSyntax) -> Int? {
        if let i = Self.intLiteral(expr) { return i }
        if let path = Self.constantAccessPath(expr), case .number(let d)? = namespaceConstants[path],
           d == d.rounded() { return Int(d) }
        return nil
    }

    /// A `Bool` from a bool literal OR a resolved bool namespace constant.
    mutating func resolveBool(_ expr: ExprSyntax) -> Bool? {
        if let b = Self.boolLiteral(expr) { return b }
        if let path = Self.constantAccessPath(expr), case .bool(let b)? = namespaceConstants[path] {
            return b
        }
        return nil
    }

    /// A plain (non-input) string from a string literal OR a resolved string namespace
    /// constant. Used for `accessibilityIdentifier` + image-name positions.
    mutating func resolvePlainString(_ expr: ExprSyntax) -> String? {
        if let s = Self.plainStringLiteral(expr) { return s }
        if let path = Self.constantAccessPath(expr), case .string(let s)? = namespaceConstants[path] {
            return s
        }
        return nil
    }

    // MARK: - Scalars

    static func doubleLiteral(_ expr: ExprSyntax) -> Double? {
        if let f = expr.as(FloatLiteralExprSyntax.self) { return Double(f.literal.text) }
        if let i = expr.as(IntegerLiteralExprSyntax.self) { return Double(i.literal.text) }
        // `CGFloat(8)` / `Double(8)` wrapper.
        if let call = expr.as(FunctionCallExprSyntax.self),
           let callee = call.calledExpression.as(DeclReferenceExprSyntax.self),
           ["CGFloat", "Double", "Float"].contains(callee.baseName.text),
           let only = call.arguments.first?.expression {
            return doubleLiteral(only)
        }
        // A negative literal `-8`.
        if let prefix = expr.as(PrefixOperatorExprSyntax.self),
           prefix.operator.text == "-", let d = doubleLiteral(prefix.expression) {
            return -d
        }
        return nil
    }

    static func intLiteral(_ expr: ExprSyntax) -> Int? {
        if let i = expr.as(IntegerLiteralExprSyntax.self) { return Int(i.literal.text) }
        return nil
    }

    static func boolLiteral(_ expr: ExprSyntax) -> Bool? {
        switch expr.trimmedDescription {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    /// The case name of a leading-dot member (`.center` → "center", `.vertical` →
    /// "vertical"), or nil. Used for axis/alignment/distribution/contentMode/
    /// textAlignment — the IR mirrors UIKit's enum case names by raw value.
    static func memberCaseName(_ expr: ExprSyntax) -> String? {
        guard let m = expr.as(MemberAccessExprSyntax.self), m.base == nil else { return nil }
        return m.declName.baseName.text
    }

    // MARK: - Fonts

    /// Translate a UIFont expression to an `IRFont(...)` guest builder, or nil.
    /// Handles: `.systemFont(ofSize:)`/`.systemFont(ofSize:weight:)`,
    /// `.boldSystemFont(ofSize:)`, `UIFont.systemFont(...)`, and
    /// `.preferredFont(forTextStyle:)`.
    static func fontLiteral(_ expr: ExprSyntax) -> FontLit? {
        guard let call = expr.as(FunctionCallExprSyntax.self),
              let member = call.calledExpression.as(MemberAccessExprSyntax.self) else { return nil }
        let fn = member.declName.baseName.text
        switch fn {
        case "systemFont":
            var size = "17", weight: String? = nil
            for arg in call.arguments {
                if arg.label?.text == "ofSize", let d = doubleLiteral(arg.expression) { size = UIKitEmitter.numLit(d) }
                if arg.label?.text == "weight", let w = memberCaseName(arg.expression) { weight = w }
            }
            let w = weight.map { ", weight: .\($0)" } ?? ""
            return FontLit(guest: "IRFont(size: \(size)\(w))")
        case "boldSystemFont":
            var size = "17"
            if let arg = call.arguments.first(where: { $0.label?.text == "ofSize" }),
               let d = doubleLiteral(arg.expression) { size = UIKitEmitter.numLit(d) }
            return FontLit(guest: "IRFont(size: \(size), weight: .bold)")
        case "preferredFont":
            if let arg = call.arguments.first(where: { $0.label?.text == "forTextStyle" }),
               let style = mapTextStyle(arg.expression) {
                return FontLit(guest: "IRFont(style: .\(style))")
            }
            return nil
        case "monospacedSystemFont", "monospacedDigitSystemFont":
            var size = "17", weight: String? = nil
            for arg in call.arguments {
                if arg.label?.text == "ofSize", let d = doubleLiteral(arg.expression) { size = UIKitEmitter.numLit(d) }
                if arg.label?.text == "weight", let w = memberCaseName(arg.expression) { weight = w }
            }
            let w = weight.map { ", weight: .\($0)" } ?? ""
            return FontLit(guest: "IRFont(size: \(size)\(w), design: .monospaced)")
        default:
            return nil
        }
    }

    /// Map `UIFont.TextStyle` cases to the IR's `IRFont.TextStyle` raw names. UIKit's
    /// `.title1/.title2/.title3` map to the IR's `.title/.title2/.title3`.
    static func mapTextStyle(_ expr: ExprSyntax) -> String? {
        guard let c = memberCaseName(expr) else { return nil }
        switch c {
        case "largeTitle": return "largeTitle"
        case "title1": return "title"
        case "title2": return "title2"
        case "title3": return "title3"
        case "headline": return "headline"
        case "subheadline": return "subheadline"
        case "body": return "body"
        case "callout": return "callout"
        case "footnote": return "footnote"
        case "caption1": return "caption"
        case "caption2": return "caption2"
        default: return nil
        }
    }

    // MARK: - Colors

    /// Translate a UIColor expression to a `ColorRef` guest builder, or nil. Handles
    /// `.systemBlue`/`.label`/`.red`-style named colors, `UIColor.systemBlue`, and
    /// `UIColor(red:green:blue:alpha:)` / `.init(white:alpha:)`.
    static func colorLiteral(_ expr: ExprSyntax) -> ColorRefLit? {
        // `.systemBlue`, `.label`, `.white` (leading-dot) — a named color.
        if let name = memberCaseName(expr), let mapped = mapColorName(name) {
            return ColorRefLit(guest: ".named(\"\(mapped)\")")
        }
        // `UIColor.systemBlue` / `UIColor.label`.
        if let m = expr.as(MemberAccessExprSyntax.self),
           m.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == "UIColor",
           let mapped = mapColorName(m.declName.baseName.text) {
            return ColorRefLit(guest: ".named(\"\(mapped)\")")
        }
        // `UIColor(red:green:blue:alpha:)`.
        if let call = expr.as(FunctionCallExprSyntax.self),
           Self.isUIColorInit(call) {
            var r = "0", g = "0", b = "0", a = "1"
            var matched = 0
            for arg in call.arguments {
                guard let d = doubleLiteral(arg.expression) else { continue }
                switch arg.label?.text {
                case "red": r = UIKitEmitter.numLit(d); matched += 1
                case "green": g = UIKitEmitter.numLit(d); matched += 1
                case "blue": b = UIKitEmitter.numLit(d); matched += 1
                case "alpha": a = UIKitEmitter.numLit(d)
                case "white": r = UIKitEmitter.numLit(d); g = r; b = r; matched += 1
                default: break
                }
            }
            guard matched > 0 else { return nil }
            return ColorRefLit(guest: ".rgba(IRColor(r: \(r), g: \(g), b: \(b), a: \(a)))")
        }
        return nil
    }

    static func isUIColorInit(_ call: FunctionCallExprSyntax) -> Bool {
        if call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text == "UIColor" { return true }
        // `.init(red:…)` leading-dot form.
        if let m = call.calledExpression.as(MemberAccessExprSyntax.self),
           m.base == nil, m.declName.baseName.text == "init" { return true }
        return false
    }

    /// Map a `UIColor` member name to the shared IR's named-color vocabulary (which
    /// the UIKit renderer's `namedColor` resolves). `systemBlue` → "blue", etc.
    static func mapColorName(_ name: String) -> String? {
        switch name {
        case "black", "white", "clear", "red", "orange", "yellow", "green",
             "blue", "purple", "brown", "gray", "label", "separator":
            return name
        case "systemRed": return "red"
        case "systemOrange": return "orange"
        case "systemYellow": return "yellow"
        case "systemGreen": return "green"
        case "systemMint": return "mint"
        case "systemTeal": return "teal"
        case "systemCyan": return "cyan"
        case "systemBlue": return "blue"
        case "systemIndigo": return "indigo"
        case "systemPurple": return "purple"
        case "systemPink": return "pink"
        case "systemBrown": return "brown"
        case "systemGray", "lightGray", "darkGray", "gray2": return "gray"
        case "secondaryLabel": return "secondary"
        case "systemBackground": return "systemBackground"
        case "secondarySystemBackground": return "secondarySystemBackground"
        case "tintColor": return "tint"
        default: return nil
        }
    }

    // MARK: - Images

    /// Translate a `UIImage(systemName:)` / `UIImage(named:)` to an `IRImageRef`
    /// builder fragment (the `UI.image(...)` arg form), or nil.
    static func imageLiteral(_ expr: ExprSyntax) -> ImageLit? {
        guard let call = expr.as(FunctionCallExprSyntax.self) else { return nil }
        let isUIImage = call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text == "UIImage"
            || call.calledExpression.as(MemberAccessExprSyntax.self)?.declName.baseName.text == "init"
        guard isUIImage else { return nil }
        for arg in call.arguments {
            if arg.label?.text == "systemName", let s = plainStringLiteral(arg.expression) {
                return ImageLit(guest: "systemName: \"\(escape(s))\"")
            }
            if arg.label?.text == "named", let s = plainStringLiteral(arg.expression) {
                return ImageLit(guest: "named: \"\(escape(s))\"")
            }
        }
        return nil
    }

    // MARK: - Selectors / button state

    /// `#selector(handleTap)` / `#selector(self.handleTap(_:))` → "handleTap".
    static func selectorBaseName(_ raw: String) -> String {
        // Strip `#selector(` … `)`.
        var s = raw
        if let open = s.range(of: "#selector(") {
            s = String(s[open.upperBound...])
            if s.hasSuffix(")") { s.removeLast() }
        }
        // `self.handleTap(_:)` → `handleTap`.
        if let dot = s.lastIndex(of: ".") { s = String(s[s.index(after: dot)...]) }
        if let paren = s.firstIndex(of: "(") { s = String(s[..<paren]) }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Whether a `setTitle`/`setTitleColor` call targets `.normal` (the only state we
    /// lower). `for: .normal` (or a missing `for:` → treat as normal).
    static func isNormalState(_ call: FunctionCallExprSyntax) -> Bool {
        guard let arg = call.arguments.first(where: { $0.label?.text == "for" }) else { return true }
        return memberCaseName(arg.expression) == "normal"
    }

    /// Map a `UILayoutPriority` expression to its rawValue Double. Handles the named
    /// cases (`.defaultHigh`/`.defaultLow`/`.required`/`.fittingSizeLevel`), a
    /// `UILayoutPriority(750)` / `.init(rawValue: 750)` wrapper, and a bare numeric.
    /// Returns nil for an unmodelable form (the caller leaves priority at default).
    static func layoutPriorityValue(_ expr: ExprSyntax) -> Double? {
        if let name = memberCaseName(expr) {
            switch name {
            case "required": return 1000
            case "defaultHigh": return 750
            case "defaultLow": return 250
            case "fittingSizeLevel": return 50
            default: return nil
            }
        }
        if let call = expr.as(FunctionCallExprSyntax.self) {
            // `UILayoutPriority(750)` / `UILayoutPriority(rawValue: 750)` / `.init(rawValue:)`.
            let isPriorityInit = call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text == "UILayoutPriority"
                || call.calledExpression.as(MemberAccessExprSyntax.self)?.declName.baseName.text == "init"
            if isPriorityInit, let only = call.arguments.first?.expression {
                return doubleLiteral(only)
            }
        }
        return doubleLiteral(expr)
    }
}
