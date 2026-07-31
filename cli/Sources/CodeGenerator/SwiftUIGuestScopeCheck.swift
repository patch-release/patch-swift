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
        // Names BOUND inside the emitted body itself (a `for x in …` loop var the
        // emitter introduced for a `ForEach`, any surviving `let`, a closure param)
        // are resolvable. Collect them up front so a reference to one isn't flagged.
        let bound = GuestBoundNameCollector.collect(tree)
        bodyScope.formUnion(bound)

        var unresolved = Set<String>()
        let bodyScanner = FreeIdentifierScanner(inScope: bodyScope, isSafe: Self.isSafeGlobal)
        bodyScanner.walk(tree)
        unresolved.formUnion(bodyScanner.unresolved)

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
}

/// Collects names BOUND within an emitted guest body: `for <x> in …` loop variables
/// (the emitter introduces these for a lowered `ForEach`), `let`/`var` declarations
/// that survived into the emitted code, and closure parameters of any emitted
/// closure. A reference to one of these is resolvable in the guest, so it must NOT be
/// flagged as a free identifier.
final class GuestBoundNameCollector: SwiftSyntax.SyntaxVisitor {
    private(set) var names: Set<String> = []

    static func collect(_ tree: SourceFileSyntax) -> Set<String> {
        let c = GuestBoundNameCollector(viewMode: .sourceAccurate)
        c.walk(tree)
        return c.names
    }

    // `let x = …` / `var x = …` / `for x in …` all bind an IdentifierPattern.
    override func visit(_ node: IdentifierPatternSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.identifier.text); return .visitChildren
    }
    // `{ x in … }` shorthand closure param.
    override func visit(_ node: ClosureShorthandParameterSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.name.text); return .visitChildren
    }
    // `{ (x: T) in … }` typed closure param.
    override func visit(_ node: ClosureParameterSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.firstName.text)
        if let second = node.secondName { names.insert(second.text) }
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
        if inScope.contains(name) || isSafe(name) { return .visitChildren }
        // Free identifier the guest scope can't resolve → record it (the view demotes).
        unresolved.insert(name)
        return .visitChildren
    }
}
