// SPDX-License-Identifier: Apache-2.0

// SwiftUIGuestScopeCheck.swift — the demote-safety guard that keeps the SwiftUI
// guest module COMPILABLE.
// ======================================================================
// The body lowering emits scalar/condition values VERBATIM from the developer's
// source (a `frame(height: Double(height))`, a `cornerRadius: Double(grid ?
// Theme.Radius.md : Theme.Radius.pill)`, a ternary `(owners.count > 1) ? … : …`).
// That is correct ONLY when every identifier the verbatim expression references
// is actually in scope in the guest `_patchBuildTree__<View>` function — i.e. it
// is a marshalled INPUT (`name`/`flag`/…), a geometry input (`__geo_*`), a
// loop-bound element the emitter introduced (`for item in …`), or a Swift/IR
// global the guest module defines (`Double`, `N`, `ViewNode`, `max`, …).
//
// A reference to ANYTHING ELSE — a computed `var height: CGFloat { … }` (skipped
// by `viewInputs`), a body-local `let owners = schedule.…` (the emitter drops
// `let` decls but a sibling node still references it), a design-system static in
// a NUMERIC position (`Theme.Radius.md` — the token path only lowers color/font
// modifier VALUES), or a Foundation type (`Locale.current.…` left in an input's
// default literal) — is a FREE identifier the guest scope can't resolve. It
// compiles to `error: cannot find 'X' in scope`, which (because all 40+ view
// exports live in ONE `_PatchSwiftUI.swift` wrapper) demotes the WHOLE module and
// ships ZERO views. This is the #1 real-app blocker.
//
// This checker finds those free references so the BuildPipeline can EXCLUDE just
// the offending view (it renders natively, demote-safe) while the other views
// still ship their exports. It is intentionally conservative: a free identifier
// we cannot prove is in scope (or a safe global) makes the view demote — faithful
// (native) over broken (a guest that won't compile).

import SwiftSyntax
import SwiftParser

/// Detects FREE identifier references in an emitted guest `N.`-builder expression
/// — references the guest `_patchBuildTree__<View>` scope can't resolve, which would
/// make the single guest wrapper fail to compile.
public enum SwiftUIGuestScopeCheck {

    /// The result of scope-checking a view's emitted guest body.
    public struct Result: Sendable, Equatable {
        /// True when every identifier the body references is in scope (a marshalled
        /// input / geo input / loop-bound element / safe global) — the guest compiles.
        public var isCompilable: Bool { unresolved.isEmpty }
        /// The free identifiers (sorted, deduped) the guest scope can't resolve. When
        /// non-empty the view must be EXCLUDED from guest emission (renders native).
        public let unresolved: [String]
        public init(unresolved: [String]) { self.unresolved = unresolved }
    }

    /// Scope-check one view's emitted guest body (and the input DEFAULT LITERALS the
    /// guest emitter bakes into the bindings).
    ///
    /// - Parameters:
    ///   - guestBody: the `N.`-builder expression `Emitter.emit` produced.
    ///   - inputNames: the view's marshalled stored-property input names (bound as
    ///     `let`s in the guest function). Includes scalar + array + struct-array.
    ///   - usesGeometry: when true the reserved `__geo_*` inputs are also in scope.
    ///   - inputDefaultLiterals: the verbatim `= …` default expression of each bound
    ///     input. The guest emitter emits `let name = _patchScan*(…) ?? <default>`, so
    ///     a default referencing a free identifier (`Locale.current.region?…`) is the
    ///     SAME `cannot find 'X' in scope` failure as one in the body. Pass `[]` to skip.
    /// - Returns: the unresolved free identifiers (empty ⇒ the body + defaults are in
    ///   scope, so the guest compiles).
    public static func check(guestBody: String,
                             inputNames: Set<String>,
                             usesGeometry: Bool,
                             inputDefaultLiterals: [String] = []) -> Result {
        // Parse the builder expression as a Swift expression (wrap in a trivial decl).
        // We use a function so a `for`/`let` statement inside an emitted row loop
        // closure parses as statements (an emitted `{ () -> [ViewNode] in … }`).
        let wrapped = "func __patch_probe() -> ViewNode {\n  return \(guestBody)\n}"
        let tree = Parser.parse(source: wrapped)

        var bodyScope = inputNames
        if usesGeometry {
            bodyScope.formUnion(["__geo_width", "__geo_height", "__geo_minX", "__geo_minY"])
        }
        // Names BOUND inside the emitted body itself (a `for x in …` loop var the emitter
        // introduced for a `ForEach`, any surviving `let`, a closure param) are resolvable —
        // but ONLY within their own scope. `FreeIdentifierScanner` resolves those per reference
        // by walking its ENCLOSING scopes; collecting them into one flat set (what this did)
        // made a name bound anywhere in the body resolvable everywhere in it, which silently
        // accepted a genuinely free reference. See `boundInEnclosingScope`.
        var unresolved = Set<String>()
        let bodyScanner = FreeIdentifierScanner(inScope: bodyScope, isSafe: Self.isSafeGlobal)
        bodyScanner.walk(tree)
        unresolved.formUnion(bodyScanner.unresolved)
        // TYPE safety for the numeric positions the emitter wraps as `Double(<expr>)`. The name
        // scan above can't see these: `nil` is a safe global and a bare implicit member
        // (`.gutter`) has no identifier at all, yet `Double(nil)` and `Double(.gutter)` are hard
        // guest-compile errors that drop the WHOLE module. Several emitter sites deliberately
        // fall back to emitting an unresolved numeric VERBATIM "so the scope check demotes
        // honestly" — this is the check that makes that true.
        let numericScanner = GuestNumericArgumentScanner(viewMode: .sourceAccurate)
        numericScanner.walk(tree)
        unresolved.formUnion(numericScanner.unresolved)
        // FOUNDATION-ONLY String members that survived into the emitted body. The `Text(…)`
        // content path host-projects these (cli 1.6.43), but other positions — an `if`
        // CONDITION most of all — emit the developer's expression verbatim, and the
        // Foundation-free guest has no `trimmingCharacters`/`capitalized`. Same failure mode:
        // the whole module, not just the view.
        let foundationScanner = GuestFoundationMemberScanner(viewMode: .sourceAccurate)
        foundationScanner.walk(tree)
        unresolved.formUnion(foundationScanner.unresolved)

        // The input DEFAULT LITERALS are emitted verbatim into the guest bindings
        // (`?? <default>`), so they must resolve too. A default's scope is the inputs +
        // geo + safe globals (NOT the body-bound loop vars — a default is evaluated
        // before any row loop). An input default that references another input is
        // unusual but legal; conservatively we allow all input names.
        if !inputDefaultLiterals.isEmpty {
            var defScope = inputNames
            if usesGeometry {
                defScope.formUnion(["__geo_width", "__geo_height", "__geo_minX", "__geo_minY"])
            }
            for lit in inputDefaultLiterals {
                let t = lit.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { continue }
                let defTree = Parser.parse(source: "let __patch_default_probe = \(t)")
                let defScanner = FreeIdentifierScanner(inScope: defScope, isSafe: Self.isSafeGlobal)
                defScanner.walk(defTree)
                unresolved.formUnion(defScanner.unresolved)
            }
        }
        return Result(unresolved: unresolved.sorted())
    }

    /// Swift-stdlib + Patch-IR global names that are ALWAYS in scope in a guest
    /// module (the IR target's public types/builders compiled into the guest, plus
    /// the Foundation-free Swift stdlib surface the emitted bodies legitimately use).
    /// A free reference to one of these is NOT a scope error; anything else free is.
    ///
    /// Kept deliberately TIGHT: only symbols the guest genuinely defines/links. A
    /// developer type that happens to match one of these is astronomically unlikely
    /// (they're stdlib/IR names), and the cost of a false "in scope" is a broken
    /// compile that the convergence loop's per-view isolation (BuildPipeline) still
    /// catches as the backstop — so this list is an optimization, not the only guard.
    static let safeGlobals: Set<String> = {
        var s = Set<String>()
        // The IR builder entry points + the NON-`IR`-prefixed value/enum types the
        // emitted `N.`/`UI.` tree and its modifiers reference by name. (The `IR*`
        // family — every `IRColor`/`IRFont`/`IRShapeStyle`/… — is matched by the
        // `IR`-prefix STRUCTURAL rule in `isSafeGlobal`, so it can't drift out of sync
        // when a new IR type is added.) These are the IR symbols that DON'T start with
        // `IR`, plus the guest emitter's own helper/wire types.
        s.formUnion([
            "N", "UI", "ViewNode", "ViewNodeWire", "NodeKind",
            "UIKitNode", "UIKitNodeKind", "UIKitViewProps", "UIKitEmission",
            "UIKitEmbeddedJSON", "UIKitCoverage",
            "BodyEmission", "DispatchResult", "DispatchEvent", "EmbeddedJSON",
            "Coverage", "EventID", "Modifier", "ColorRef", "ShapeKind",
            "TextStyle", "Weight",
        ])
        // Swift stdlib types/constructors + free functions the emitted bodies use in
        // scalar/numeric positions (a `Double(x)` cast, a `max(a, b)` clamp). These are
        // the stdlib free identifiers the lowering emits live.
        s.formUnion([
            "Double", "Float", "Int", "Int8", "Int16", "Int32", "Int64",
            "UInt", "UInt8", "UInt16", "UInt32", "UInt64", "Bool", "String",
            "Character", "Array", "Set", "Dictionary", "Optional", "Range",
            "ClosedRange", "CGFloat",
            // `UTF8` (Unicode.UTF8): the codec `GuestNonASCIIEncoder` emits in
            // `String(decoding: [..] as [UInt8], as: UTF8.self)` for a non-ASCII literal.
            "UTF8", "Unicode",
            "max", "min", "abs", "true", "false", "nil",
        ])
        return s
    }()

    /// Whether `name` is an always-in-scope global in a guest module. Combines the
    /// explicit `safeGlobals` set with the STRUCTURAL rule that every Patch IR value
    /// type is `IR`-prefixed (`IRColor`, `IRShapeStyle`, `IRTransition`, …) — so a
    /// newly-added IR type the emitter starts using never needs this list updated (the
    /// gap that let `IRShapeStyle`/`IRTransition` slip past an explicit-only list).
    /// `IR` followed by an uppercase letter is the IR namespace; a developer type named
    /// `IRsomething` lowercase, or a bare `IR`, is not matched.
    static func isSafeGlobal(_ name: String) -> Bool {
        if safeGlobals.contains(name) { return true }
        if name.hasPrefix("IR"), name.count > 2 {
            let after = name[name.index(name.startIndex, offsetBy: 2)]
            return after.isUppercase
        }
        return false
    }

    /// Stdlib TYPE names the guest links. Their STATIC members are in scope ONLY when they are
    /// stdlib members: an app that EXTENDS one — `extension String { static func formated(key:…) }`,
    /// a real corpus app — gives the DEVELOPER'S file a member the Foundation-free guest has never
    /// heard of. Because `isSafeGlobal("String")` is true and the scanner only resolves the BASE of
    /// a member access, `String.formated(key:…)` sailed through the check and then failed the guest
    /// compile (`type 'String' has no member 'formated'`) — which drops the WHOLE module, so the
    /// app ships zero views with no diagnostic. Flagging the static member makes that view demote
    /// (native, faithful) and names the real symbol in the report.
    static let stdlibTypeNames: Set<String> = [
        "Double", "Float", "Int", "Int8", "Int16", "Int32", "Int64",
        "UInt", "UInt8", "UInt16", "UInt32", "UInt64", "Bool", "String",
        "Character", "Array", "Set", "Dictionary", "Optional", "Range",
        "ClosedRange", "CGFloat", "UTF8", "Unicode",
    ]

    /// Static members of a `stdlibTypeNames` type the GUEST genuinely has. A member whose name
    /// starts with an uppercase letter is a nested TYPE reference (`Unicode.UTF8`, `String.Index`)
    /// and is accepted structurally — an app doesn't add uppercase statics.
    static let guestStdlibStaticMembers: Set<String> = [
        "self", "Type", "init",
        "max", "min", "zero", "pi", "infinity", "nan", "signalingNaN",
        "greatestFiniteMagnitude", "leastNormalMagnitude", "leastNonzeroMagnitude", "ulpOfOne",
        "bitWidth", "random",
    ]

    /// Whether `base.member` is an in-scope STATIC member access for the guest (see
    /// `stdlibTypeNames`). Non-stdlib bases are not this rule's business (`true`).
    static func isResolvableStaticMember(base: String, member: String) -> Bool {
        guard stdlibTypeNames.contains(base) else { return true }
        if let first = member.first, first.isUppercase { return true }
        return guestStdlibStaticMembers.contains(member)
    }
}

/// Flags the numeric-conversion calls the emitter wraps scalar positions in
/// (`Double(<expr>)`, `Int(<expr>)`, …) whose argument cannot type-check in the guest:
///
///   * a `nil` literal — `.frame(height: hidden ? 0 : nil)` emitted
///     `Double((hidden) ? 0 : nil)` → `'nil' cannot be used in context expecting type 'Double'`;
///   * a bare IMPLICIT-MEMBER access that isn't a stdlib `FloatingPoint` static —
///     `HStack(spacing: .gutter)` over an app's `extension CGFloat { static let gutter }`
///     emitted `Double(.gutter)`, which the guest resolves against whatever `Double.init`
///     overload wins (`type 'Substring' has no member 'gutter'`).
///
/// Both were found by the corpus `--wasm-compile` sweep (WWDC, firefox-ios): the view lowers
/// statically, the guest module then fails, and production's convergence loop drops it with no
/// diagnostic. Flagging them here demotes just that view, which is the faithful outcome — and it
/// covers EVERY emitter site at once, including the several that emit an unresolved numeric
/// verbatim on purpose, relying on this check to catch it.
final class GuestNumericArgumentScanner: SwiftSyntax.SyntaxVisitor {
    private(set) var unresolved: Set<String> = []

    /// The scalar conversions the emitter emits around a developer expression.
    static let numericConversions: Set<String> = ["Double", "Float", "Int", "CGFloat"]

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard let callee = node.calledExpression.as(DeclReferenceExprSyntax.self),
              Self.numericConversions.contains(callee.baseName.text),
              node.arguments.count == 1, let arg = node.arguments.first else {
            return .visitChildren
        }
        let scanner = NumericGuestTypeSafetyScanner(viewMode: .sourceAccurate)
        scanner.walk(Syntax(arg.expression))
        if !scanner.isSafe {
            unresolved.insert("\(callee.baseName.text)(\(arg.expression.trimmedDescription))")
        }
        return .visitChildren
    }
}

/// Flags a FOUNDATION-ONLY `String` member left in the emitted guest body. The emitter already
/// knows these are absent from the Foundation-free guest (it host-projects them to a
/// `__strtok_` in the `Text(…)` content position — cli 1.6.43), but the knowledge was applied
/// per-position: a wire-ios `if !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty`
/// went out verbatim in an `if` CONDITION and failed the whole module
/// (`value of type 'String' has no member 'trimmingCharacters'`). Checking the finished body
/// covers every position at once; a projected read has no such member left to find, so a view
/// that took the projection path is unaffected.
/// SCOPE: only a Foundation-only METHOD **call** (`x.trimmingCharacters(in:)`). The PROPERTY
/// forms (`capitalized`, `localizedUppercase`) are deliberately NOT flagged here: with no type
/// information, `movie.capitalized` is indistinguishable from a marshalled struct field that
/// happens to be named `capitalized` — which is a legitimate guest read, and pinned as one by
/// `SwiftUITokenLoweringTests`. A call to a method of that name on a non-String is not a real
/// shape, so the call form discriminates cleanly.
final class GuestFoundationMemberScanner: SwiftSyntax.SyntaxVisitor {
    private(set) var unresolved: Set<String> = []

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let callee = node.calledExpression.as(MemberAccessExprSyntax.self), callee.base != nil {
            let member = callee.declName.baseName.text
            if Emitter.foundationOnlyStringMethodNames.contains(member) {
                unresolved.insert(".\(member)")
            }
        }
        return .visitChildren
    }
}

/// Scans a parsed guest body for FREE value identifiers — a `DeclReferenceExpr`
/// whose base identifier is neither in scope (input / geo / bound) nor a safe
/// global. A member access (`Theme.Radius.md`, `owners.count`, `Locale.current`)
/// is flagged on its BASE identifier only (`Theme`/`owners`/`Locale`), since the
/// member names after the dot are properties of that base, not free names. The
/// member of a member-access (`.md` in `Theme.Radius.md`) is itself a
/// `DeclReferenceExpr` but is never the BASE, so the "skip non-base members" rule
/// keeps us from flagging `.md`/`.count` (which would be noise).
final class FreeIdentifierScanner: SwiftSyntax.SyntaxVisitor {
    private let inScope: Set<String>
    private let isSafe: (String) -> Bool
    private(set) var unresolved: Set<String> = []

    init(inScope: Set<String>, isSafe: @escaping (String) -> Bool) {
        self.inScope = inScope
        self.isSafe = isSafe
        super.init(viewMode: .sourceAccurate)
    }

    /// Whether `name` is bound by one of `node`'s ENCLOSING scopes — the emitted row loop's
    /// `for <x> in …`, a closure parameter, or a `let`/`var` in an enclosing block.
    ///
    /// This replaces a flat "every name bound anywhere in the body is in scope" set, which was
    /// unsound in exactly the case that matters: the emitted row loop binds `item`, and a
    /// SIBLING node outside that loop that references a body-local ALSO called `item` (the
    /// developer's `let item = store.current`, dropped by the emitter) was then accepted. The
    /// engine deliberately emits an inaccessible read VERBATIM and relies on this check to
    /// demote the view — so accepting it shipped a guest that fails `cannot find 'item' in
    /// scope`, taking the whole module down.
    ///
    /// Deliberately slightly permissive within a scope (it does not model declaration ORDER,
    /// and a `for x in x…` sequence counts as inside the loop): being permissive there only
    /// affects code the guest compiler would reject anyway, and the cost of a false FLAG is a
    /// needless demote.
    static func boundInEnclosingScope(_ node: Syntax, _ name: String) -> Bool {
        var current: Syntax? = node.parent
        while let scope = current {
            if let loop = scope.as(ForStmtSyntax.self), patternBinds(loop.pattern, name) { return true }
            if let closure = scope.as(ClosureExprSyntax.self),
               let params = closure.signature?.parameterClause {
                switch params {
                case .simpleInput(let list):
                    if list.contains(where: { $0.name.text == name }) { return true }
                case .parameterClause(let clause):
                    if clause.parameters.contains(where: {
                        $0.firstName.text == name || $0.secondName?.text == name
                    }) { return true }
                }
            }
            if let ifExpr = scope.as(IfExprSyntax.self) {
                for condition in ifExpr.conditions {
                    if case .optionalBinding(let binding) = condition.condition,
                       patternBinds(binding.pattern, name) { return true }
                }
            }
            if let block = scope.as(CodeBlockItemListSyntax.self) {
                for item in block {
                    if let decl = item.item.as(VariableDeclSyntax.self),
                       decl.bindings.contains(where: { patternBinds($0.pattern, name) }) { return true }
                }
            }
            current = scope.parent
        }
        return false
    }

    /// Whether a binding pattern introduces `name` (an identifier, or an element of a tuple
    /// pattern like `for (i, row) in …`).
    static func patternBinds(_ pattern: PatternSyntax, _ name: String) -> Bool {
        if let ident = pattern.as(IdentifierPatternSyntax.self) { return ident.identifier.text == name }
        if let tuple = pattern.as(TuplePatternSyntax.self) {
            return tuple.elements.contains { patternBinds($0.pattern, name) }
        }
        if let valueBinding = pattern.as(ValueBindingPatternSyntax.self) {
            return patternBinds(valueBinding.pattern, name)
        }
        return false
    }

    /// A TYPE the emitted body NAMES — in an `is`/`as?`/`as!` cast (`if value is Special`), a
    /// closure/annotation, a generic argument. These are `TypeSyntax`, NOT `DeclReferenceExpr`,
    /// so the expression scan below never saw them: `((value is Special) ? … : …)` passed the
    /// check and then failed the guest with `cannot find type 'Special' in scope`, taking the
    /// WHOLE module (every view in the app) with it. No app type exists in the guest, so a type
    /// name that is neither a safe global nor an in-scope name is always a compile error — and
    /// the view must demote. The types the emitter itself names (`ViewNode`, `[UInt8]`, the
    /// `IR*` family) are safe globals.
    override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        if !name.isEmpty, name != "_", !inScope.contains(name), !isSafe(name) {
            unresolved.insert(name)
        }
        return .visitChildren
    }

    /// `Foo.Bar` in a type position: only the ROOT is a free name (`Bar` is nested in `Foo`).
    override func visit(_ node: MemberTypeSyntax) -> SyntaxVisitorContinueKind {
        // Visit only the base type; the member name is a nested type of it.
        walk(node.baseType)
        if let args = node.genericArgumentClause { walk(args) }
        return .skipChildren
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        let name = node.baseName.text
        // Skip a member name (the `.member` of `base.member`): it's a property/case of
        // the base, not a free name. Only flag a reference that is NOT the `.member`
        // position — i.e. a bare reference or the BASE of a member access.
        if let parent = node.parent?.as(MemberAccessExprSyntax.self),
           parent.declName.id == node.id {
            // This DeclRef is the `.member` of a member access — never a free name.
            return .visitChildren
        }
        // Skip the function name in a call's member position handled above; a bare
        // function call (`max(a,b)`) flags `max`, which is in `safe`.
        guard !name.isEmpty else { return .visitChildren }
        // Operators / wildcards aren't identifiers we resolve here.
        if name == "_" { return .visitChildren }
        // A STATIC member of a stdlib TYPE (`String.formated(key:…)`) is only in scope when the
        // GUEST has that member — the app may have extended the type in its own module. Checked
        // BEFORE the safe-global test, because the BASE resolving is exactly what used to let it
        // through; see `isResolvableStaticMember`.
        if let parent = node.parent?.as(MemberAccessExprSyntax.self), parent.base?.id == node.id,
           !inScope.contains(name),
           !SwiftUIGuestScopeCheck.isResolvableStaticMember(
                base: name, member: parent.declName.baseName.text) {
            unresolved.insert("\(name).\(parent.declName.baseName.text)")
            return .visitChildren
        }
        if inScope.contains(name) || isSafe(name) { return .visitChildren }
        // Bound by one of this reference's OWN enclosing scopes (the emitted `for x in …` row
        // loop, a closure parameter, a surviving `let`)? Then it resolves.
        if Self.boundInEnclosingScope(Syntax(node), name) { return .visitChildren }
        // Free identifier the guest scope can't resolve → record it (the view demotes).
        unresolved.insert(name)
        return .visitChildren
    }
}
