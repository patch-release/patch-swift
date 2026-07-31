// SPDX-License-Identifier: Apache-2.0

// Classifier.swift — walks a body expression tree, classifying each
// primitive/container/modifier as lowerable (→ ViewNode IR) or native fallback.
//
// The set of LOWERABLE constructs is exactly the ViewNode IR's surface:
//   primitives:  Text, Image(systemName:), Spacer, Divider, Color, Rectangle,
//                RoundedRectangle, Circle, Ellipse, Capsule, Label(_:systemImage:)
//   containers:  VStack, HStack, ZStack, Group, ForEach, Button, ScrollView,
//                List, Section, Form, LazyVStack→vstack, LazyHStack→hstack,
//                NavigationStack, NavigationView→navigationStack
//   modifiers:   font, foregroundColor/foregroundStyle, bold, italic, padding,
//                frame, background, cornerRadius, opacity, lineLimit,
//                multilineTextAlignment, onTapGesture, navigationTitle
// Result-builder composition (statement lists, if/else, ForEach) is understood.
// Everything else degrades to a native fallback (counted, with a reason).

import SwiftSyntax
import ViewNodeIR

struct Classifier {
    var elements: [ClassifiedElement] = []

    /// Same-struct inline-lowerable helper members (name → body statements), set by
    /// `BodyLowering` (TASK 2). When the body references a collected helper (a bare
    /// `header`, or a no-arg `makeRow()`), the classifier walks the helper's body
    /// inline (so coverage reflects the inlined content, matching the emitter) instead
    /// of counting the reference as a custom-view fallback. A re-entrant reference is
    /// guarded by `inliningHelpers`.
    var helperBodies: [String: CodeBlockItemListSyntax] = [:]
    private var inliningHelpers: Set<String> = []

    /// Classify a collected helper's body inline (returns true when `name` was an
    /// inlinable helper and got walked). On a RE-ENTRANT reference (the recursion
    /// guard) it returns FALSE so the caller counts the reference as a fallback —
    /// matching the emitter, which slots the re-entrant reference as `.opaque`.
    private mutating func classifyInlineHelper(_ name: String) -> Bool {
        guard let stmts = helperBodies[name] else { return false }
        guard inliningHelpers.insert(name).inserted else { return false }
        defer { inliningHelpers.remove(name) }
        classify(expr: stmts)
        return true
    }

    // The view primitives/containers we can lower (constructor name → ok).
    // The INTERACTIVE controls (Toggle/Slider/Stepper/TextField) now lower too:
    // they carry a binding/event id and the native renderer wires the real
    // SwiftUI control's two-way Binding back to the guest's `dispatch`.
    static let lowerableNodes: Set<String> = [
        "Text", "Image", "Spacer", "Divider", "Color", "ProgressView",
        "Rectangle", "RoundedRectangle", "Circle", "Ellipse", "Capsule",
        "VStack", "HStack", "ZStack", "Group", "ForEach", "Button",
        "Toggle", "Slider", "Stepper", "TextField",
        // IR v2 containers + navigation shell. `LazyVStack`/`LazyHStack` now lower to
        // distinct lazy nodes; `NavigationView` (legacy) maps to navigationStack;
        // `Form`→form, `List`→list, `Section`→section, `ScrollView`→scrollView.
        "ScrollView", "List", "Section", "Form", "LazyVStack", "LazyHStack",
        "Label", "NavigationStack", "NavigationView",
        // Leaf-views + container expansion. The EMITTER is the source of truth on
        // whether a given CALL lowers (e.g. a non-literal AsyncImage URL, a bound
        // TabView/DisclosureGroup still slot); these names are *eligible*.
        "AsyncImage", "Gauge", "Link", "ShareLink", "SecureField", "TextEditor",
        "LabeledContent", "Menu", "EmptyView", "AnyView", "TabView",
        "LazyVGrid", "LazyHGrid", "Grid", "GridRow", "GroupBox",
        "DisclosureGroup", "ViewThatFits", "ControlGroup",
        // Host-state (B — selection / navigation). The EMITTER is the source of
        // truth on whether a given CALL lowers (a custom Hashable Picker tag, a
        // value-based NavigationLink, etc. still slot); these names are *eligible*.
        "Picker", "NavigationLink", "EditButton",
        // GeometryReader (C): promoted to host-state. The emitter lowers
        // `GeometryReader { proxy in <body> }` when every `proxy` use maps to a
        // reserved geo input (`proxy.size.width`→`__geo_width`, etc.); an unmappable
        // `proxy` use (`proxy[anchor]`, `proxy.safeAreaInsets`, `proxy.size` whole)
        // still slots. (`Canvas` stays NATIVE-only — the engine can't faithfully
        // parse imperative `GraphicsContext` draw closures — so it is NOT listed.)
        "GeometryReader"
    ]

    // The modifiers we can lower. `.onTapGesture` is now lowered as a discrete
    // event (a tap → a guest `dispatch`), so it moves out of the native set.
    // IR v2 adds the flexible `.frame` form plus `.tint`/`.clipShape`/`.disabled`/
    // `.fixedSize`. The MODIFIER-surface expansion adds the styling/layout/
    // transform/text/control/gesture/lifecycle/animation modifiers below. The
    // emitter is the SOURCE OF TRUTH on whether a given CALL actually lowers
    // (a form it can't faithfully rebuild returns nil → the node slots to native).
    static let lowerableModifiers: Set<String> = [
        "font", "foregroundColor", "foregroundStyle", "bold", "italic",
        "padding", "frame", "background", "cornerRadius", "opacity",
        "lineLimit", "multilineTextAlignment", "onTapGesture",
        "navigationTitle", "tint", "clipShape", "disabled", "fixedSize", "trim",
        // Styling (IRShapeStyle vocabulary)
        "fill", "stroke", "strokeBorder", "border", "overlay", "mask", "shadow",
        // Layout
        "offset", "position", "aspectRatio", "scaledToFit", "scaledToFill",
        "clipped", "layoutPriority", "safeAreaInset", "ignoresSafeArea",
        "zIndex", "containerRelativeFrame", "allowsHitTesting", "scrollClipDisabled",
        "scrollContentBackground", "listRowSeparator", "listRowBackground",
        "listRowInsets", "listSectionSeparator",
        // Transforms & visual effects
        "rotationEffect", "rotation3DEffect", "scaleEffect", "blur",
        "brightness", "contrast", "saturation", "grayscale", "hueRotation",
        "colorInvert", "blendMode",
        // Text styling
        "fontWeight", "fontDesign", "underline", "strikethrough", "kerning",
        "tracking", "baselineOffset", "lineSpacing", "textCase",
        "minimumScaleFactor", "truncationMode", "monospaced", "monospacedDigit",
        "redacted", "unredacted", "symbolRenderingMode", "symbolVariant",
        "imageScale", "dynamicTypeSize",
        // Control config (built-in named styles only)
        "buttonStyle", "listStyle", "pickerStyle", "toggleStyle", "labelStyle",
        "gaugeStyle", "progressViewStyle", "menuStyle", "buttonBorderShape",
        "controlSize", "tabViewStyle", "indexViewStyle",
        "keyboardType", "textContentType", "autocorrectionDisabled",
        "textInputAutocapitalization", "submitLabel", "preferredColorScheme",
        "accentColor",
        // Gestures
        "onLongPressGesture", "gesture", "highPriorityGesture", "simultaneousGesture",
        // Lifecycle
        "onAppear", "onDisappear", "onChange", "task", "onSubmit", "onHover",
        "sensoryFeedback",
        // Animation
        "animation", "transition",
        // `.contextMenu { items }` wraps the base content in a contextMenu node
        // (the items-builder form; the emitter slots the preview/selection forms).
        "contextMenu",
        // Host-state (B — presentation / navigation / focus / list-editing). These
        // own SwiftUI presentation/selection/focus state the SDK now bridges (the
        // Bool/token/array binding). The emitter lowers the `isPresented:`/scalar
        // forms; an `item:`-with-body-local or a form it can't faithfully rebuild
        // still slots. (`sheet`/`fullScreenCover`/`alert`/`navigationDestination`/
        // `focused` MOVED here from `knownNativeModifiers`.)
        "sheet", "fullScreenCover", "popover", "alert", "confirmationDialog",
        "navigationDestination", "toolbar", "navigationBarTitleDisplayMode",
        "navigationBarBackButtonHidden", "searchable", "focused",
        "onDelete", "onMove",
        // Legacy nav API (G9). (presentationDetents/presentationDragIndicator were
        // tried but REVERTED — lowering them regressed a real app's RemindersQuickSheet
        // 44→43 by re-exposing a non-reconstructable @State read; they slot instead.)
        "navigationBarTitle", "navigationViewStyle",
        // Per-key environment value (G7). The emitter lowers the reconstructable
        // keys (layoutDirection/colorScheme/locale) and slots everything else
        // (incl. `.environment(object)` / `.environmentObject(_)`).
        "environment",
        // Accessibility (G8). String-literal label/hint/value, bool hidden, named
        // trait sets. A non-literal label or `Text(...)`-arg form slots.
        "accessibilityLabel", "accessibilityHint", "accessibilityValue",
        "accessibilityHidden", "accessibilityAddTraits", "accessibilityRemoveTraits",
        // Scroll & layout (sweep — added at END). Pure-data scroll/layout modifiers
        // the renderer reapplies as the real SwiftUI modifier. The emitter is the
        // source of truth: a bool/enum/numeric-literal form lowers, anything else
        // slots. (`.scrollPosition`/`.matchedGeometryEffect` are NOT here — they need
        // a binding/`@Namespace` we can't faithfully reconstruct, so they keep
        // slotting.)
        "scrollDisabled", "scrollIndicators", "scrollTargetBehavior",
        "scrollTargetLayout", "scrollBounceBehavior", "contentMargins", "safeAreaPadding"
    ]

    // Modifiers we recognize but deliberately classify as native-fallback,
    // with a clear reason (the honest-limits surface). NOTE: several formerly-
    // native modifiers (onAppear/onDisappear/animation/transition/task/gesture,
    // and now sheet/fullScreenCover/alert/navigationDestination/focused) LOWER
    // above (the emitter lowers the recognized forms; an unhandled form slots).
    static let knownNativeModifiers: [String: String] = [
        // `.environment(\.key, value)` LOWERS (the emitter handles the reconstructable
        // keys; an object/unknown-key form slots). `.environmentObject(_)` stays native.
        "environmentObject": "environment (host-owned)"
    ]

    mutating func classify(expr items: CodeBlockItemListSyntax) {
        for item in items {
            classifyItem(item.item)
        }
    }

    private mutating func classifyItem(_ item: CodeBlockItemSyntax.Item) {
        switch item {
        case .expr(let e):
            classifyExpr(e)
        case .stmt(let s):
            classifyStmt(s)
        case .decl:
            // a `let`/`var` binding inside the builder — pure structure setup,
            // not itself a node. Ignored for counting.
            break
        }
    }

    private mutating func classifyStmt(_ stmt: StmtSyntax) {
        // Result-builder control flow: if/else and for (ForEach desugars to a
        // ForEach call, but plain `for` loops in a builder are also valid).
        if let ifStmt = stmt.as(ExpressionStmtSyntax.self)?.expression {
            classifyExpr(ifStmt)
            return
        }
        if let exprStmt = stmt.as(ExpressionStmtSyntax.self) {
            classifyExpr(exprStmt.expression)
            return
        }
        // An if/switch used as a builder branch: SwiftSyntax models `if { } else { }`
        // as an `IfExprSyntax` wrapped in an ExpressionStmt in builders; but a
        // bare `if` statement appears as `IfExprSyntax` here too in 603.
        if let ifExpr = stmt.as(ExpressionStmtSyntax.self)?.expression.as(IfExprSyntax.self) {
            classifyIf(ifExpr)
            return
        }
    }

    private mutating func classifyExpr(_ expr: ExprSyntax) {
        // if/else used as an expression in a @ViewBuilder
        if let ifExpr = expr.as(IfExprSyntax.self) {
            classifyIf(ifExpr)
            return
        }
        // A modifier chain ends in a member-access call: `Base.modifier(args)`.
        // Peel the outermost modifier, recurse into the base.
        if let call = expr.as(FunctionCallExprSyntax.self) {
            classifyCall(call)
            return
        }
        // A bare member access like `Color.red` (no call) — still a node. But
        // `self.header` referencing a same-struct inline helper lowers inline (TASK 2).
        if let member = expr.as(MemberAccessExprSyntax.self) {
            if member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == "self",
               classifyInlineHelper(member.declName.baseName.text) {
                return
            }
            classifyBareMember(member)
            return
        }
        // A bare identifier: a same-struct `some View` helper (`header`) lowers inline
        // (TASK 2); anything else (a `let card = ...; card`) can't be proven pure
        // structure statically ⇒ native fallback.
        if let ref = expr.as(DeclReferenceExprSyntax.self) {
            if classifyInlineHelper(ref.baseName.text) { return }
            addNode(name: expr.trimmedDescription, lowered: false,
                    reason: "reference to non-inlineable view value")
            return
        }
    }

    private mutating func classifyIf(_ ifExpr: IfExprSyntax) {
        // The condition is host/native state; the BRANCHES are structure. We
        // count the branches' contents. (A lowered guest evaluates the
        // condition from marshalled-in inputs.) The `if` itself is free.
        classify(expr: ifExpr.body.statements)
        if let elseBody = ifExpr.elseBody {
            switch elseBody {
            case .codeBlock(let cb): classify(expr: cb.statements)
            case .ifExpr(let nested): classifyIf(nested)
            }
        }
    }

    private mutating func classifyCall(_ call: FunctionCallExprSyntax) {
        // Case 1: `Base.modifier(args)` — a modifier applied to a base view.
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
            let modName = member.declName.baseName.text

            // Distinguish a *modifier on a view* (member has a non-trivial base
            // that is itself a view expression) from a *type member call* like
            // `Color.red` won't be a call; `Image(systemName:)` is plain.
            if let base = member.base {
                // It's `<base>.<modName>(...)`. Classify the modifier, recurse base.
                classifyModifier(name: modName, on: base, call: call)
                return
            } else {
                // `.something(...)` with no base — a leading-dot static call used
                // as a node (rare in bodies). Treat as native fallback.
                addNode(name: ".\(modName)", lowered: false,
                        reason: "leading-dot expression")
                return
            }
        }

        // Case 2: `Constructor(args)` — a view primitive/container constructor.
        if let callee = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            classifyConstructor(name: callee.baseName.text, call: call)
            return
        }

        // Anything else callable (a closure call, subscript-chain) — fallback.
        addNode(name: call.calledExpression.trimmedDescription, lowered: false,
                reason: "non-constructor call")
    }

    private mutating func classifyModifier(name: String, on base: ExprSyntax,
                                           call: FunctionCallExprSyntax) {
        if Classifier.lowerableModifiers.contains(name) {
            addModifier(name: ".\(name)", lowered: true)
        } else if let reason = Classifier.knownNativeModifiers[name] {
            addModifier(name: ".\(name)", lowered: false, reason: reason)
        } else {
            addModifier(name: ".\(name)", lowered: false, reason: "unsupported modifier")
        }
        // Modifiers whose CLOSURES are view content (not actions): the contextMenu
        // items, and the host-state presentation bodies (sheet/cover/popover content;
        // alert/confirmationDialog actions+message; navigationDestination body;
        // toolbar items). Classify that content so coverage reflects it. (The action
        // modifiers' closures are behavior, not nodes, and are NOT walked.)
        let contentClosureModifiers: Set<String> = [
            "contextMenu", "sheet", "fullScreenCover", "popover",
            "alert", "confirmationDialog", "navigationDestination", "toolbar"
        ]
        if contentClosureModifiers.contains(name) {
            classifyTrailingClosures(call)
        }
        // `.listRowBackground(<view>)` carries an INLINE view expression (not a
        // closure) as its row background — classify it so coverage reflects it.
        if name == "listRowBackground" {
            for a in call.arguments where a.label == nil {
                if !a.expression.is(ClosureExprSyntax.self) { classifyExpr(a.expression) }
            }
        }
        // Recurse into the base (which may itself be a modifier chain or a node).
        classifyExpr(base)
    }

    private mutating func classifyConstructor(name: String, call: FunctionCallExprSyntax) {
        // A NO-ARG call to a same-struct `@ViewBuilder func makeRow() -> some View`
        // helper lowers inline (TASK 2) — classify its body so coverage reflects it.
        if call.arguments.isEmpty, call.trailingClosure == nil, helperBodies[name] != nil,
           classifyInlineHelper(name) {
            return
        }
        let lowerable = Classifier.lowerableNodes.contains(name)
        if !lowerable {
            addNode(name: name, lowered: false,
                    reason: "custom/unsupported view type")
            // Still recurse into a trailing closure's contents if any — a custom
            // container might wrap lowerable children we can still count.
            classifyTrailingClosures(call)
            return
        }

        // Special-case Text/Image content lowerability:
        if name == "Text" {
            // Text("literal") or Text(stringVar) — both lower (string is an
            // input). Text(verbatim:) / interpolation also lower. Only a Text
            // built from a non-string (e.g. Text(Image...)) wouldn't; rare.
            addNode(name: "Text", lowered: true)
            return
        }
        if name == "Image" {
            // `Image(systemName:)` lowers (image / symbolImage w/ variableValue), and
            // a string-LITERAL `Image("asset")` lowers to `bundleImage` (the shipped
            // Asset Catalog, a data lookup). `Image(uiImage:)` / a computed name stays
            // a native fallback.
            if hasArgumentLabel(call, "systemName") {
                addNode(name: "Image(systemName:)", lowered: true)
            } else if let only = call.arguments.first, call.arguments.count == 1,
                      only.label == nil,
                      only.expression.as(StringLiteralExprSyntax.self) != nil {
                addNode(name: "Image(asset)", lowered: true)
            } else {
                addNode(name: "Image", lowered: false,
                        reason: "non-SF-symbol image (native asset)")
            }
            return
        }
        if name == "Button" {
            // Button(action:label:) or Button("title", action:) — lowers (action→id).
            // IMPORTANT: only the LABEL is view content. The action closure is
            // host behavior, NOT a node — walking it would mis-count `foo()` in
            // the action body as a fallback view. So classify only the label.
            addNode(name: "Button", lowered: true)
            classifyButtonLabel(call)
            return
        }
        if name == "ForEach" {
            addNode(name: "ForEach", lowered: true)
            classifyTrailingClosures(call)   // the row builder
            return
        }
        if name == "Label" {
            // Only `Label("Title", systemImage: "sf")` lowers (title + SF symbol,
            // both strings — no view-content children). The `Label { } icon: { }`
            // builder form, or an asset `image:` icon, degrades to native.
            if hasArgumentLabel(call, "systemImage") {
                addNode(name: "Label(systemImage:)", lowered: true)
            } else {
                addNode(name: "Label", lowered: false,
                        reason: "Label without systemImage (builder/asset icon)")
                classifyTrailingClosures(call)
            }
            return
        }
        if name == "Section" {
            // `Section { content } header: { } footer: { }` (and the string-titled
            // `Section("Title") { rows }`). Header/footer/content are ALL view
            // content — classify every closure (the generic walker does this); a
            // string title is implied (lowered to a Text header), not a child.
            addNode(name: "Section", lowered: true)
            classifyTrailingClosures(call)
            // `header:`/`footer:` can also be a single INLINE view expression
            // (`Section(header: Text("X"))`), not a closure — classify those too so
            // the coverage report reflects the header/footer content.
            for arg in call.arguments where arg.label?.text == "header" || arg.label?.text == "footer" {
                if !arg.expression.is(ClosureExprSyntax.self) {
                    classifyExpr(arg.expression)
                }
            }
            return
        }
        // Interactive controls: lower the NODE; the binding (`isOn:`/`value:`/
        // `text:`) becomes an event id (host wiring), NOT view content. Only a
        // Toggle/Stepper LABEL closure is view content; a string title is implied.
        if name == "Toggle" {
            addNode(name: "Toggle", lowered: true)
            classifyControlLabel(call)
            return
        }
        if name == "Stepper" {
            addNode(name: "Stepper", lowered: true)
            classifyControlLabel(call)
            return
        }
        if name == "Slider" {
            // Slider has no label content (just a bound value + range).
            addNode(name: "Slider", lowered: true)
            return
        }
        if name == "TextField" {
            // TextField's first arg is the placeholder (a string); the `text:`
            // binding becomes the event id. No view-content children.
            addNode(name: "TextField", lowered: true)
            return
        }
        if name == "SecureField" || name == "TextEditor" {
            // Value-only controls (the binding is the event); no view content.
            addNode(name: name, lowered: true)
            return
        }
        if name == "AnyView" {
            // `AnyView(x)` unwraps to the inner node — classify that inner arg (not a
            // closure) so its structure is counted.
            addNode(name: "AnyView", lowered: true)
            if let inner = call.arguments.first(where: { $0.label == nil }) {
                classifyExpr(inner.expression)
            }
            return
        }
        if name == "EmptyView" {
            // `EmptyView()` → an empty group. No children.
            addNode(name: "EmptyView", lowered: true)
            return
        }
        if name == "AsyncImage" {
            // The DEFAULT form lowers (the real AsyncImage); a content/placeholder
            // closure form slots (the emitter is the source of truth) — don't walk
            // its closures here (they bind a body-local `image`/`phase`).
            addNode(name: "AsyncImage", lowered: true)
            return
        }
        if name == "Gauge" {
            // The value/label form lowers; the label closure (if any) is view content.
            addNode(name: "Gauge", lowered: true)
            classifyControlLabel(call)
            return
        }

        // Generic lowerable node (Spacer, Divider, Color, stacks, shapes, Group).
        addNode(name: name, lowered: true)
        classifyTrailingClosures(call)
    }

    private mutating func classifyBareMember(_ member: MemberAccessExprSyntax) {
        // `Color.red`, `Color.primary` — a lowerable color node.
        if let base = member.base?.as(DeclReferenceExprSyntax.self),
           base.baseName.text == "Color" {
            addNode(name: "Color.\(member.declName.baseName.text)", lowered: true)
            return
        }
        // `EmptyView()` style is a call, handled elsewhere. Other bare members
        // (an enum case used as a view?) — fallback.
        addNode(name: member.trimmedDescription, lowered: false,
                reason: "non-view member expression")
    }

    // Classify ONLY a Button's label content (never its action closure).
    //   Button("Title") { action }         -> label is the "Title" string literal
    //   Button("Title", action: foo)        -> label is the "Title" string literal
    //   Button(action: foo) { Text("Hi") }  -> label is the trailing closure
    //   Button { action } label: { … }      -> label is the `label:` closure
    private mutating func classifyButtonLabel(_ call: FunctionCallExprSyntax) {
        // String-titled button: the title IS the label (a Text). It's already
        // implied by the Button node; no extra child to classify.
        let firstUnlabeled = call.arguments.first { $0.label == nil }
        if let first = firstUnlabeled,
           first.expression.as(StringLiteralExprSyntax.self) != nil {
            return
        }
        // Explicit `label:` trailing closure (multiple-trailing-closure form).
        for add in call.additionalTrailingClosures where add.label.text == "label" {
            classify(expr: add.closure.statements)
            return
        }
        // `label:` as a normal argument.
        for arg in call.arguments where arg.label?.text == "label" {
            if let closure = arg.expression.as(ClosureExprSyntax.self) {
                classify(expr: closure.statements)
                return
            }
        }
        // Form `Button(action:){ label }`: when `action:` is a labeled arg, the
        // SOLE trailing closure is the label.
        let hasActionArg = call.arguments.contains { $0.label?.text == "action" }
        if hasActionArg, let trailing = call.trailingClosure {
            classify(expr: trailing.statements)
        }
    }

    // Classify ONLY a control's label content (Toggle/Stepper). A string title
    // is the label and is implied by the node (no extra child). A trailing
    // closure (or explicit `label:`) is the label @ViewBuilder content.
    private mutating func classifyControlLabel(_ call: FunctionCallExprSyntax) {
        let firstUnlabeled = call.arguments.first { $0.label == nil }
        if let first = firstUnlabeled,
           first.expression.as(StringLiteralExprSyntax.self) != nil {
            return   // string title — implied
        }
        for add in call.additionalTrailingClosures where add.label.text == "label" {
            classify(expr: add.closure.statements); return
        }
        for arg in call.arguments where arg.label?.text == "label" {
            if let closure = arg.expression.as(ClosureExprSyntax.self) {
                classify(expr: closure.statements); return
            }
        }
        // `Toggle(isOn:$x){ label }` / `Stepper(value:$n){ label }`: when the
        // binding is a labeled arg, the sole trailing closure is the label.
        let hasBindingArg = call.arguments.contains {
            $0.label?.text == "isOn" || $0.label?.text == "value" || $0.label?.text == "text"
        }
        if hasBindingArg, let trailing = call.trailingClosure {
            classify(expr: trailing.statements)
        }
    }

    // Walk trailing + paren closures that act as @ViewBuilder child content.
    private mutating func classifyTrailingClosures(_ call: FunctionCallExprSyntax) {
        if let trailing = call.trailingClosure {
            classify(expr: trailing.statements)
        }
        for add in call.additionalTrailingClosures {
            classify(expr: add.closure.statements)
        }
        // A closure passed as a normal argument (e.g. ForEach(items) { ... }
        // already handled by trailingClosure; but VStack(content:) explicit).
        for arg in call.arguments {
            if let closure = arg.expression.as(ClosureExprSyntax.self) {
                classify(expr: closure.statements)
            }
        }
    }

    // MARK: helpers

    private func hasArgumentLabel(_ call: FunctionCallExprSyntax, _ label: String) -> Bool {
        call.arguments.contains { $0.label?.text == label }
    }

    private mutating func addNode(name: String, lowered: Bool, reason: String? = nil) {
        elements.append(ClassifiedElement(category: .node, name: name,
                                          lowered: lowered, reason: reason))
    }
    private mutating func addModifier(name: String, lowered: Bool, reason: String? = nil) {
        elements.append(ClassifiedElement(category: .modifier, name: name,
                                          lowered: lowered, reason: reason))
    }
}
