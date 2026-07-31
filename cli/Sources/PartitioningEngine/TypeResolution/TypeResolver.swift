// SPDX-License-Identifier: Apache-2.0

import Foundation
import SwiftSyntax
import SwiftParser

/// Per-function, scope-aware type resolution and call resolution over a
/// `SymbolTable`. This is the type-resolution layer's working end: it replaces
/// the engine's *name-based* call resolution with a real *type-resolved*
/// analysis.
///
/// For a function body it produces a `ResolvedFunction`:
///   - **resolvedCalls**: each call site resolved to its concrete target
///     record-id(s) (instead of every same-named record in the project), with the
///     receiver's inferred type when known.
///   - **localTypes**: the inferred concrete type of every local binding (`let
///     x: T`, `let x = T(...)`, `let x = expr` for the common cases), threaded
///     scope-by-scope. This is what lets the splitter give fragments concrete
///     param/return types so they compile.
///
/// SAFETY: the resolver only ever lets a downstream consumer *prove* a target /
/// type. Unknown receivers, ambiguous overloads it cannot disambiguate, and
/// dynamically-dispatched protocol calls all degrade to "all candidates" or
/// "unresolved", which the classifier handles conservatively (→ native). It can
/// never assert a target/type it has not derived from the source.
public struct TypeResolver {
    public let table: SymbolTable

    public init(table: SymbolTable) { self.table = table }

    /// A single resolved call site inside a function body.
    public struct ResolvedCall: Sendable, Hashable {
        /// Simple method/function name at the call site.
        public let name: String
        /// Argument labels at the call site (`_` for unlabelled).
        public let argLabels: [String]
        /// The inferred receiver type for a `recv.method(...)` call (nil for a
        /// free call or an unresolved receiver).
        public let receiverType: String?
        /// Concrete target record-ids this call resolves to. EMPTY = unresolved
        /// (the call graph keeps it as an unresolved reference → registry scan →
        /// conservative). A SINGLE element = precisely resolved. MULTIPLE =
        /// genuine dynamic dispatch over the type's real conformers (bounded, not
        /// the whole project's same-named methods).
        public let targetRecordIDs: [String]
        /// True when resolution was bounded to a type's real members (precise),
        /// vs falling back to a project-wide name match.
        public let isPrecise: Bool
        /// The call's result type if the resolved member declares one.
        public let resultType: String?

        public init(name: String, argLabels: [String], receiverType: String?,
                    targetRecordIDs: [String], isPrecise: Bool, resultType: String?) {
            self.name = name; self.argLabels = argLabels; self.receiverType = receiverType
            self.targetRecordIDs = targetRecordIDs; self.isPrecise = isPrecise
            self.resultType = resultType
        }
    }

    /// The resolution result for one function body.
    public struct ResolvedFunction: Sendable {
        public let resolvedCalls: [ResolvedCall]
        /// Inferred concrete type of each in-scope local binding (and params).
        public let localTypes: [String: String]
    }

    /// Resolve a function body given its self-type and parameter types.
    /// `selfType` is the enclosing type's name (nil for a free function).
    public func resolve(body: CodeBlockItemListSyntax,
                        selfType: String?,
                        paramTypes: [String: String]) -> ResolvedFunction {
        var scope = Scope(table: table, selfType: selfType)
        for (n, t) in paramTypes { scope.bind(n, type: t) }
        // Also bind the enclosing type's stored/computed properties so `recv = x`
        // where `x` is a property resolves, and `self`-implicit member access works.
        if let selfType, let decl = table.types[selfType] {
            for m in decl.members where m.kind == .property {
                if let rt = m.returnType { scope.bindProperty(m.name, type: rt) }
            }
        }
        let walker = BodyWalker(resolver: self, scope: scope)
        walker.walk(body)
        return ResolvedFunction(resolvedCalls: walker.calls, localTypes: walker.scope.allLocals())
    }

    // MARK: - Call resolution

    /// Resolve a `recv.method(labels)` (or free `method(labels)`) call to concrete
    /// target record ids, given the receiver's inferred type (nil = free/unknown).
    func resolveCall(name: String, argLabels: [String], receiverType: String?) -> ResolvedCall {
        // (1) Receiver type known → bound to that type's members + its conformers
        //     for protocol/superclass dynamic dispatch. PRECISE.
        if let receiverType, let canon = table.canonicalType(receiverType) {
            let direct = table.members(named: name, on: canon).filter { $0.kind == .method }
            if !direct.isEmpty {
                let best = bestOverloads(direct, argLabels: argLabels)
                // If the receiver is a protocol/base type, also include conformers'
                // overrides (bounded dynamic dispatch over the REAL implementors).
                var ids = best.compactMap { $0.recordID }
                if let decl = table.types[canon], decl.kind == .protocol || decl.kind == .class {
                    for conformer in table.conformers(of: canon) {
                        let cms = (table.types[conformer]?.membersByName[name] ?? [])
                            .filter { $0.kind == .method }
                        for m in bestOverloads(cms, argLabels: argLabels) {
                            if let rid = m.recordID { ids.append(rid) }
                        }
                    }
                }
                return ResolvedCall(name: name, argLabels: argLabels, receiverType: canon,
                                    targetRecordIDs: Array(Set(ids)), isPrecise: true,
                                    resultType: Self.unambiguousReturnType(best))
            }
            // Receiver type known but method not found on it → likely a stdlib/
            // Foundation/native member. Unresolved (registry scan handles it).
            return ResolvedCall(name: name, argLabels: argLabels, receiverType: canon,
                                targetRecordIDs: [], isPrecise: true, resultType: nil)
        }

        // (2) Free function call `method(labels)`.
        if let fns = table.freeFunctions[name], !fns.isEmpty {
            let best = bestOverloads(fns, argLabels: argLabels)
            return ResolvedCall(name: name, argLabels: argLabels, receiverType: nil,
                                targetRecordIDs: best.compactMap { $0.recordID },
                                isPrecise: true, resultType: Self.unambiguousReturnType(best))
        }
        // (3) `Type(...)` initializer call (callee is an UpperCamel type name passed
        //     as receiverType==name handled by caller). Fall through → unresolved.
        return ResolvedCall(name: name, argLabels: argLabels, receiverType: receiverType,
                            targetRecordIDs: [], isPrecise: false, resultType: nil)
    }

    /// The single result type shared by every best-overload member, or nil when
    /// they disagree (or none declare one). SymbolTable unions same-name types
    /// across files, so a tie between `fetch() -> Int` (file A) and `fetch() ->
    /// String` (file B) must NOT pick an arbitrary `.first` returnType — an
    /// arbitrary pick mis-types a call result threaded into a fragment signature
    /// (and is nondeterministic across file-iteration order). When ambiguous we
    /// return nil (the call's result type is simply unknown — demote-safe via the
    /// WasmConvergence loop, never a wrong assertion).
    private static func unambiguousReturnType(_ members: [SymbolTable.Member]) -> String? {
        let declared = Set(members.compactMap { $0.returnType })
        return declared.count == 1 ? declared.first : nil
    }

    /// Pick the overload(s) matching the call's argument labels exactly; if none
    /// match labels, fall back to arity match; if still none, return all (the
    /// caller treats multiple as conservative dynamic dispatch).
    private func bestOverloads(_ members: [SymbolTable.Member], argLabels: [String]) -> [SymbolTable.Member] {
        let methods = members.filter { $0.kind == .method || $0.kind == .initializer }
        guard !methods.isEmpty else { return members }
        // Exact label-sequence match (the real overload-resolution win).
        let byLabels = methods.filter { matchesLabels($0.argLabels, callLabels: argLabels) }
        if byLabels.count == 1 { return byLabels }
        if !byLabels.isEmpty { return byLabels }
        // Arity match.
        let byArity = methods.filter { $0.argLabels.count == argLabels.count }
        if !byArity.isEmpty { return byArity }
        return methods
    }

    /// Whether a declared label list matches a call's labels. Unlabelled
    /// parameters (`_`) appear as "" at call sites, so compare the present labels.
    private func matchesLabels(_ declared: [String], callLabels: [String]) -> Bool {
        // Declared labels: "_" means unlabelled. Call labels: only the labelled
        // args carry a label; unlabelled args contribute nothing. Build the
        // declared "expected call label" sequence and compare against present.
        let expected = declared.filter { $0 != "_" }
        let present = callLabels.filter { !$0.isEmpty }
        if expected == present { return true }
        // Arity-aware fallback: same number of params as call args.
        return declared.count == callLabels.count
    }
}
