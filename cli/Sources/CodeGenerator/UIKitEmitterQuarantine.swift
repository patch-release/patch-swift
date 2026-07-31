// SPDX-License-Identifier: Apache-2.0

// UIKitEmitterQuarantine.swift — GRANULAR PER-STATEMENT PARTITIONING (Goal 1).
// =============================================================================
// Kills the all-or-nothing-per-method demote rule. Historically, the FIRST
// unrecognized statement in a `setupViews()`/`configure(with:)`/`viewDidLoad`
// called `bail(...)` and the WHOLE method demoted to native — one weird imperative
// line was contagious. This file QUARANTINES a single unrecognized statement as a
// NATIVE EFFECT instead of demoting: the declarative construction around it still
// lowers to the `UIKitNode` tree, and the odd imperative line is replayed VERBATIM
// by the build-time thunk (against `self` + the rendered view) in SOURCE ORDER.
//
// This GENERALIZES the two pre-existing view/method effect levers — `addGesture-
// Recognizer` (a view-attached native replay) and `NotificationCenter.addObserver`
// (a method-level native replay) — into one path any isolatable statement can take.
//
// ## Correctness (the whole point — demote-safe + build-safe over coverage)
// A statement is quarantined ONLY when ALL hold (else the method still demotes):
//
//   * BUILD-SAFE — its verbatim text compiles in the cross-file thunk's
//     `extension <Cell>` scope: it references NO method-local binding, NO
//     `private`/`fileprivate` member, and NO marshalled model field (the thunk's
//     `self` is the cell, not the row model). The same `ReferencedNameScanner`
//     reachability gate the design-system token channel already uses.
//
//   * NO DOUBLE-SET CONFLICT — an ASSIGNMENT effect never writes a property the
//     lowered tree ALSO expresses for the same view. The native effect touches only
//     state the declarative tree does NOT model, so deferring it past tree-build
//     (the replay point) can never disagree with the tree on a shared property —
//     the build-order-vs-replay-order question is moot for disjoint state.
//
//   * ISOLATABLE RECEIVER — the effect operates on `self`, an inherited-or-global
//     object (`navigationController`, `view`, `NotificationCenter`, `navigationItem`),
//     or a STORED member the thunk reaches (`self.tableView.delegate = self`). It is
//     replayed VERBATIM against `self` — the original text compiles unchanged in the
//     cross-file `extension <Cell>` (every member it names is accessible there). A
//     receiver that is a method-LOCAL binding (thunk-unreachable) demotes. NB: we do
//     NOT rewrite the receiver to the rendered view — a generic `UIView` param can't
//     type-check a concrete-type member (`UITableView.delegate`), and the dominant
//     real receiver (a `UITableView`/`UIScrollView`/`MKMapView` stored prop) renders
//     as a SLOTTED custom leaf that IS `self.<name>`, so replaying against `self`
//     configures exactly the shown view. For a stored prop that renders as a LOWERED
//     widget, the effect targets a fresh node → at worst an invisible no-op, never a
//     wrong render (and a modeled-property set is blocked above, so no double-set).
//
//   * NOT A DECL / CONTROL-FLOW — a `let x = …` binds a value later lowered
//     statements may consume (a data dependency the engine can't track across the
//     thunk's separate closures); a `for`/`while`/`guard` carries structure the tree
//     must reflect. Those still demote (conservative). Only EXPRESSION statements
//     (an assignment or a call) are quarantine candidates.
//
// The effects ride the thunk wiring + node ids — exactly like the gesture/observer
// levers — so there is NO IR / wire-format change.

import SwiftSyntax
import ViewNodeIR

extension UIKitEmitter {

    /// Properties the lowered tree MODELS (folds into the `UIKitNode`/leaf payload). An
    /// assignment to one of these on a known view is NOT quarantinable — replaying it
    /// natively post-build would double-set a property the declarative tree also set,
    /// and the build-order-vs-replay-order could disagree. Such a set must lower (the
    /// recognized path) or demote — never become a silent native effect. (Layout/anchor
    /// props are set via `NSLayoutConstraint`, not a `view.prop =`, so they aren't here;
    /// `translatesAutoresizingMaskIntoConstraints`/`isActive`/`priority` are recognized
    /// before the quarantine path and never reach it.)
    static let modeledViewProperties: Set<String> = [
        "backgroundColor", "tintColor", "alpha", "clipsToBounds", "isHidden",
        "accessibilityIdentifier", "cornerRadius", "text", "font", "textColor",
        "numberOfLines", "textAlignment", "image", "contentMode", "axis", "spacing",
        "alignment", "distribution", "isOn", "value", "minimumValue", "maximumValue",
        "placeholder", "masksToBounds",
        // Constraint-structure props: `<constraint>.isActive = true` / `.priority = …`
        // activate/tune the Auto-Layout tree the lowered IR models (resolved via the
        // recognized constraint path or demoted) — never a silent native effect, which
        // would double-apply with any partially-resolved IR constraint.
        "isActive", "priority",
    ]

    // MARK: - Entry point

    /// Try to QUARANTINE an otherwise-unrecognized expression statement as a native
    /// effect (Goal 1). Returns true if it was recorded (the caller then continues,
    /// NOT bailing); false if it isn't isolatable/build-safe (the caller bails as
    /// before — the whole method demotes, conservative). Only called for an EXPRESSION
    /// statement that fell through every recognized-grammar case.
    mutating func tryQuarantine(_ expr: ExprSyntax) -> Bool {
        // BUILD-SAFE = DEMOTE-SAFE: a quarantined native effect is replayed VERBATIM and
        // UNCONDITIONALLY against `self` — it cannot carry a per-instance guest visibility
        // gate. Inside a model-driven `if` branch (`pendingVisibility != nil`), recording
        // the effect would LOSE that gate and replay it on every cell/row (a wrong always-on
        // render). Mirror `applyPendingVisibility`'s custom-slot bail: refuse to quarantine
        // under a visibility context so the caller restores its bail and the whole method
        // demotes to native (honest over a silently-ungated effect).
        if pendingVisibility != nil { return false }
        // An ASSIGNMENT `lhs = rhs` — a property set we don't model.
        if let assign = Self.asAssignment(expr) {
            return quarantineAssignment(lhs: assign.lhs, rhs: assign.rhs, whole: expr)
        }
        // A CALL `recv.method(args)` / bare `method(args)` — a live-object effect.
        if let call = expr.as(FunctionCallExprSyntax.self) {
            return quarantineCall(call)
        }
        return false
    }

    // MARK: - Assignment effects

    private mutating func quarantineAssignment(lhs: ExprSyntax, rhs: ExprSyntax,
                                               whole: ExprSyntax) -> Bool {
        // Decompose the lhs receiver + the assigned property. A bare-identifier lhs
        // (`backgroundColor = …`) targets the root `self`; a member lhs (`v.prop`,
        // `v.layer.prop`) targets the chain's HEAD identifier.
        let (headName, prop) = Self.lhsHeadAndProp(lhs)

        // NEVER quarantine a set of a property the lowered tree models — that must lower
        // or demote, never become a silent native double-set.
        //
        // The conflict only exists when the receiver is a KNOWN VIEW the tree renders (the
        // tree + the replayed effect would both write that view's prop). A BARE-identifier
        // set (`backgroundColor = .clear` — head=nil → the cell/`self` itself) targets a
        // surface the tree does NOT model: a cell's content tree is rooted at `contentView`,
        // so the CELL's own `self.backgroundColor` is a disjoint layer behind it (no
        // double-set). (A VC/View's bare-ident set is already claimed by Lever A's root-prop
        // fold BEFORE the quarantine path runs, so this only reaches a CELL here.) Replaying
        // `self.backgroundColor = .clear` verbatim against `self` sets the real cell
        // background natively — faithful, build-safe, and demote-safe: it lets the
        // surrounding declarative construction lower instead of the whole method demoting.
        if let prop, Self.modeledViewProperties.contains(prop), headName != nil {
            return false
        }

        return recordEffect(receiverName: headName, whole: whole)
    }

    // MARK: - Call effects

    /// Methods that STRUCTURALLY MUTATE a view's subview/child hierarchy or layer tree —
    /// exactly the structure the lowered `UIKitNode` tree models. Quarantining one of these
    /// as a native effect would DOUBLE-MUTATE (e.g. `stack.addArrangedSubview(UILabel())`
    /// appends a native child on top of the lowered children, or `view.bringSubviewToFront`
    /// reorders a tree we control). Such a call must LOWER (the recognized path) or DEMOTE
    /// — never become a silent native effect on a view the tree renders. (A receiver OUTSIDE
    /// the tree — `self`/a non-rendered member — is fine: `recordEffect` routes that to a
    /// self-effect, where no tree conflict exists, so this guard only fires for a rendered
    /// known view; we apply it uniformly + conservatively.)
    static let structuralMutationMethods: Set<String> = [
        "addSubview", "addArrangedSubview", "insertSubview", "insertArrangedSubview",
        "removeArrangedSubview", "removeFromSuperview", "exchangeSubview",
        "bringSubviewToFront", "sendSubviewToBack", "addSublayer", "insertSublayer",
        "addChild", "addChildViewController",
        // The variadic addSubviews/addArrangedSubviews helper convention (Lever C) — same
        // subview-tree mutation; a partially-recognized variadic call (one known view + one
        // literal `UIView()`) bails AFTER appending the known children, so quarantining the
        // whole call would double-add. Must lower or demote.
        "addSubviews", "addArrangedSubviews",
        // Auto-Layout activation IS the constraint tree the lowered IR models — and a
        // partially-resolved `NSLayoutConstraint.activate([...])` (one element resolves
        // onto a node THEN a later one bails) would already have mutated view state, so
        // quarantining the whole call would DOUBLE-apply (the partial IR constraints + a
        // native replay). Must lower or demote, never quarantine.
        "activate", "deactivate", "addConstraint", "addConstraints", "removeConstraint",
        "removeConstraints",
        // VIEW/METHOD WIRING the dedicated effect-replay levers (§B.4) own + APPLY TO THE
        // RENDERED NODE (gesture wirings keyed by node id, observers/targets resolved with a
        // native `#selector`). Replaying `box.addGestureRecognizer(...)` / `v.addTarget(...)`
        // VERBATIM against `self` would attach to the NATIVE `self.box` (NOT the rendered
        // node the user sees) — wrong. When the dedicated lever DECLINES (a non-self target,
        // an unknown view, a non-`#selector` action, a stored-then-configured recognizer),
        // the intent is DEMOTE, not a mis-targeted native replay. So these are never quarantined.
        "addGestureRecognizer", "removeGestureRecognizer", "addTarget", "removeTarget",
        "addInteraction", "addObserver", "removeObserver",
        // `[a, b].forEach(parent.addArrangedSubview)` (Lever F) wires the subview tree the
        // lowered IR models (and a method-ref `forEach` has NO trailing closure, so it
        // wouldn't be caught by the closure-arg guard). When Lever F DECLINES (a non-view
        // array element, an unrecognized closure body), the intent is DEMOTE — never a native
        // replay that double-adds against `self`. So `forEach` is never quarantined.
        "forEach",
    ]

    private mutating func quarantineCall(_ call: FunctionCallExprSyntax) -> Bool {
        // A trailing-closure call is NOT isolatable — the closure body is guest-
        // unreconstructable logic that may capture/mutate construction state. Demote.
        guard call.trailingClosure == nil, call.additionalTrailingClosures.isEmpty else {
            return false
        }
        // A call argument that is itself a CLOSURE (`x.sink { … }`) is the same hazard.
        for arg in call.arguments {
            if arg.expression.is(ClosureExprSyntax.self) { return false }
        }
        // A STRUCTURAL-MUTATION call (`stack.addArrangedSubview(UILabel())`, `view.
        // bringSubviewToFront(x)`) mutates the subview/child tree the lowered IR models —
        // it must lower or demote, never silently double-mutate as a native effect. Demote.
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self),
           Self.structuralMutationMethods.contains(member.declName.baseName.text) {
            return false
        }
        if let callee = call.calledExpression.as(DeclReferenceExprSyntax.self),
           Self.structuralMutationMethods.contains(callee.baseName.text) {
            return false
        }
        // The receiver is the HEAD identifier of the called member chain
        // (`view.bringSubviewToFront(x)` → `view`; `navigationController?.setX(…)` →
        // `navigationController`). A BARE free call (`setupConstraints()`, `helper()`) is
        // NOT quarantined: its body may BUILD view structure (a `setupView()`-style helper
        // we couldn't inline), and replaying it natively would add subviews the patched root
        // occludes (a degraded render). Only a MEMBER call on a receiver — a config effect on
        // a known object — is a quarantine candidate. (A bare `setNeedsLayout()` is a rare
        // loss, but demoting it is the safe call.)
        guard let member = call.calledExpression.as(MemberAccessExprSyntax.self) else {
            return false
        }
        // R2-#8: a `self.<method>(...)` (or bare-head member call resolving to a same-class
        // instance method) is NOT a vetted side-effect — an arbitrary helper may BUILD view
        // structure (`self.decorate(for: style)` adding subviews), and replaying it natively
        // on EVERY cell reuse would accumulate native subviews atop the patched root (a
        // degraded, duplicating render). The bare free-call path above already demotes a
        // `helper()` for this reason; do the same for the QUALIFIED `self.helper(...)` form.
        // Only demote a method we recognize as same-class; a `self.someInheritedConfig(...)`
        // we can't see isn't a same-class helper here (it falls through to the receiver gate,
        // which vouches `self`). Scoped to a method NAME on the cell + its extensions.
        let head = Self.chainHeadName(member.base)
        let methodName = member.declName.baseName.text
        if (head == nil || head == "self"), selfMethodNames.contains(methodName) {
            return false
        }
        return recordEffect(receiverName: head, whole: ExprSyntax(call))
    }

    // MARK: - Shared recording

    /// Curated UIKit/Foundation INHERITED-or-GLOBAL receiver names the cross-file thunk can
    /// reference without the engine cataloguing them — `self`-inherited VC/View/cell members
    /// (`view`, `navigationItem`, `navigationController`, …) + well-known global types
    /// (`NotificationCenter`, `NSLayoutConstraint`, `UIView`). A native-effect receiver that
    /// is one of these is vouched-for reachable (the verbatim replay compiles in the thunk).
    static let vouchedGlobalReceivers: Set<String> = [
        // Inherited UIViewController / UIView / cell members the thunk's `self` has.
        "view", "navigationItem", "navigationController", "tabBarController",
        "splitViewController", "presentationController", "parent", "contentView", "layer",
        "safeAreaLayoutGuide", "layoutMarginsGuide", "readableContentGuide", "window",
        "traitCollection", "tabBarItem",
        // Global types whose statics/singletons are reachable everywhere.
        "NotificationCenter", "NSLayoutConstraint", "UIView", "UIApplication", "UIAccessibility",
    ]

    /// Record `whole` as a native effect if it is isolatable + build-safe. `receiverName`
    /// is the head identifier of the statement's receiver chain (nil = a `self`/bare
    /// receiver, e.g. `title = …` / `edgesForExtendedLayout = …` — a set of a `self`
    /// property). The effect is replayed VERBATIM against `self` (`viewNodeID = nil`) — the
    /// original text compiles unchanged in the cross-file `extension <Cell>`. Returns false
    /// (→ the caller demotes) UNLESS the receiver is VOUCHED-FOR reachable AND the full
    /// statement references only thunk-visible identifiers (build-safe over coverage — an
    /// unknown free identifier would not compile in the thunk).
    private mutating func recordEffect(receiverName: String?, whole: ExprSyntax) -> Bool {
        // RECEIVER GATE (build-safety): the engine must be able to VOUCH that the receiver is
        // reachable from the cross-file thunk. A nil receiver is a bare `self`-property
        // set/call (always reachable). A named receiver must be a stored VIEW, an accessible
        // declared MEMBER of the cell, or a curated inherited/global name — else demote (an
        // unknown free identifier like a typo or a member the engine can't see would not
        // compile in the verbatim thunk replay).
        if let receiverName, receiverName != "self" {
            // A method-LOCAL binding (a `let v = …` var) is never reachable.
            if localNames.contains(receiverName), !storedViewNames.contains(receiverName) {
                return false
            }
            let vouched = storedViewNames.contains(receiverName)
                || reachableMemberNames.contains(receiverName)
                || Self.vouchedGlobalReceivers.contains(receiverName)
            guard vouched else { return false }
        }
        // FULL-STATEMENT reachability: even with a vouched receiver, the rest of the
        // statement must name only thunk-visible identifiers (no method-local arg, no
        // `private` member, no marshalled model field).
        guard isThunkReachable(whole) else { return false }
        let source = whole.trimmedDescription
        guard !source.isEmpty else { return false }
        nativeEffects.append(.init(source: source, ordinal: nextOrdinal()))
        return true
    }

    private mutating func nextOrdinal() -> Int {
        defer { effectOrdinal += 1 }
        return effectOrdinal
    }

    // MARK: - Build-safety (thunk reachability)

    /// Whether `expr` references ONLY identifiers the cross-file thunk can see — i.e. it
    /// references NONE of: a method-LOCAL binding (a `let`/`var` declared in the method,
    /// minus the stored-view names which ARE reachable as `self` members), a `private`/
    /// `fileprivate` member, or a marshalled model field (the thunk's `self` isn't the row
    /// model). This is the load-bearing BUILD-SAFETY gate — a statement that survives it
    /// compiles verbatim in the cross-file `extension <Cell>` scope.
    private func isThunkReachable(_ expr: ExprSyntax) -> Bool {
        // Method-local bindings the thunk can't reach = everything bound locally EXCEPT the
        // stored-view names (those are `self` members the thunk reaches).
        let methodLocals = localNames.subtracting(storedViewNames)
        let blocked = methodLocals.union(inaccessibleNames).union(marshalledInputNames())
        guard !blocked.isEmpty else { return true }
        return !ReferencedNameScanner.referencesAny(expr, of: blocked)
    }

    // MARK: - Receiver decomposition + rewriting

    /// The HEAD identifier + the assigned PROPERTY of an assignment lhs.
    ///   * bare `prop`              → (nil, "prop")              [a root/self set]
    ///   * `recv.prop`              → ("recv", "prop")
    ///   * `recv.layer.prop`        → ("recv", "prop")  (head is the chain root)
    ///   * `recv?.prop`             → ("recv", "prop")  (optional-chained)
    /// A non-member, non-identifier lhs returns (nil, nil) — not quarantinable as a set.
    static func lhsHeadAndProp(_ lhs: ExprSyntax) -> (head: String?, prop: String?) {
        if let ref = lhs.as(DeclReferenceExprSyntax.self) {
            return (nil, ref.baseName.text)   // bare `backgroundColor = …` → self root
        }
        guard let member = lhs.as(MemberAccessExprSyntax.self) else { return (nil, nil) }
        let prop = member.declName.baseName.text
        return (chainHeadName(member.base), prop)
    }

    /// The HEAD identifier of a member/optional chain (`a.b.c` → "a", `a?.b` → "a",
    /// `self.x` → "self"), or nil for a non-identifier head.
    static func chainHeadName(_ expr: ExprSyntax?) -> String? {
        guard var cur = expr else { return nil }
        // Peel member/optional-chaining layers to the head.
        while true {
            if let chain = cur.as(OptionalChainingExprSyntax.self) { cur = chain.expression; continue }
            if let member = cur.as(MemberAccessExprSyntax.self) {
                guard let base = member.base else { return member.declName.baseName.text }
                cur = base; continue
            }
            if let call = cur.as(FunctionCallExprSyntax.self) {
                // A call in the chain head (`a().b`) — head is the callee's head.
                cur = call.calledExpression; continue
            }
            if let ref = cur.as(DeclReferenceExprSyntax.self) { return ref.baseName.text }
            return nil
        }
    }
}
