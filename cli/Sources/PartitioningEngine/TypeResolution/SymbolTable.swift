// SPDX-License-Identifier: Apache-2.0

import Foundation
import SwiftSyntax
import SwiftParser

/// A project-wide, scope-aware symbol table built from SwiftSyntax — the
/// foundation of the type-resolution layer (Track A).
///
/// It works on *non-building* code: it depends only on parsing each `.swift`
/// file (most corpus apps don't compile headlessly), never on a successful
/// build or index-store. If an index-store *is* available a caller MAY enhance
/// precision, but it is optional and not required here.
///
/// What it captures, per project:
///   - **types**: every struct/class/enum/actor/protocol, with its declared
///     stored/computed property types, method signatures (with argument labels +
///     parameter types + return type), initializer signatures, inheritance and
///     protocol conformances, and the file/module it lives in.
///   - **free functions**: top-level (module-scope) funcs with signatures.
///   - **typealiases**: `typealias X = Y` so a member access through `X` resolves
///     against `Y`.
///   - **imports** per file (for module-qualified disambiguation, best-effort).
///
/// SAFETY: this table only ever lets the engine *prove* a resolved target. When
/// it cannot resolve precisely it returns *nothing* (or all candidates), and the
/// downstream classifier defaults to native — so a missing/wrong entry can only
/// cost OTA coverage, never break the zero-false-negative invariant.
public struct SymbolTable: Sendable {

    /// A declared member (method / computed-or-stored property / init / subscript)
    /// of a type, with everything resolution needs.
    public struct Member: Sendable, Hashable {
        public enum Kind: String, Sendable, Hashable { case method, property, initializer, `subscript` }
        public let kind: Kind
        /// The simple name (`save`, `tier`, `init`).
        public let name: String
        /// Argument labels for a method/init, in order (`_` for unlabelled).
        public let argLabels: [String]
        /// Parameter types in order (best-effort textual types).
        public let paramTypes: [String]
        /// Declared return / property type, trimmed (nil = inferred/unknown).
        public let returnType: String?
        /// True if `static`/`class` member (called on the metatype).
        public let isStatic: Bool
        /// The fully-qualified id of the owning declaration record, if a
        /// `FunctionRecord` was emitted for it (so the call graph can add a precise
        /// edge). nil for stored properties / decls without a body record.
        public let recordID: String?

        public init(kind: Kind, name: String, argLabels: [String], paramTypes: [String],
                    returnType: String?, isStatic: Bool, recordID: String?) {
            self.kind = kind; self.name = name; self.argLabels = argLabels
            self.paramTypes = paramTypes; self.returnType = returnType
            self.isStatic = isStatic; self.recordID = recordID
        }

        /// The Swift-style selector for a method/init: `save(_:)`, `init(url:)`.
        public var selector: String {
            guard kind == .method || kind == .initializer || kind == .subscript else { return name }
            let labels = argLabels.map { $0 == "_" ? "_:" : "\($0):" }.joined()
            return "\(name)(\(labels))"
        }
    }

    /// A declared type (struct/class/enum/actor/protocol).
    public struct TypeDecl: Sendable {
        public enum Kind: String, Sendable { case `struct`, `class`, `enum`, actor, `protocol` }
        public let name: String
        public let kind: Kind
        /// Inherited base class / conformed protocols (leading identifiers).
        public let inherits: [String]
        /// Declared members, indexed below by name.
        public let members: [Member]
        public let membersByName: [String: [Member]]

        public init(name: String, kind: Kind, inherits: [String], members: [Member]) {
            self.name = name; self.kind = kind; self.inherits = inherits; self.members = members
            self.membersByName = Dictionary(grouping: members, by: { $0.name })
        }
    }

    /// All declared types, keyed by simple name. (Same-named types across modules
    /// are merged — conservative: more candidate members, never fewer.)
    public let types: [String: TypeDecl]
    /// Module-scope free functions, keyed by simple name.
    public let freeFunctions: [String: [Member]]
    /// `typealias X = Y` → Y's leading identifier.
    public let typeAliases: [String: String]
    /// Global `let`/`var` declared types, keyed by name (module-scope constants).
    public let globals: [String: String]

    /// Names the project FRESHLY declares as a nominal type via an actual
    /// `struct`/`class`/`enum`/`actor`/`protocol` declaration (NOT merely an
    /// `extension`). Distinct from `types.keys`, which also contains framework
    /// types the project only *extends* (`extension UIView {…}` registers `UIView`
    /// so members resolve). Only fresh declarations shadow a framework symbol of
    /// the same name; an extension does not. The classifier uses THIS set (never
    /// `types.keys`) for shadowing so `extension UIView` can never suppress the
    /// real `UIView` native hit — preserving zero false negatives.
    public let freshlyDeclaredTypeNames: Set<String>

    /// Subset of `freshlyDeclaredTypeNames` that are VALUE types (struct/enum) or
    /// typealiases. The conservative shadowing policy uses ONLY this set: a
    /// value-type collision (e.g. swift-collections' `Path`/`Index` structs) is a
    /// monotonic OTA win, whereas shadowing a pervasive reference type that anchors
    /// auto-splits (e.g. RxSwift's `Observable` class) can perturb the realized
    /// split count. Reference-type shadowing is therefore gated out by default.
    public let freshlyDeclaredValueTypeNames: Set<String>

    public init(types: [String: TypeDecl], freeFunctions: [String: [Member]],
                typeAliases: [String: String], globals: [String: String],
                freshlyDeclaredTypeNames: Set<String> = [],
                freshlyDeclaredValueTypeNames: Set<String> = []) {
        self.types = types; self.freeFunctions = freeFunctions
        self.typeAliases = typeAliases; self.globals = globals
        self.freshlyDeclaredTypeNames = freshlyDeclaredTypeNames
        self.freshlyDeclaredValueTypeNames = freshlyDeclaredValueTypeNames
    }

    public static let empty = SymbolTable(types: [:], freeFunctions: [:], typeAliases: [:], globals: [:])

    // MARK: - Resolution helpers

    /// Canonicalise a type name: strip optionals/arrays/generics down to the
    /// leading nominal identifier, then follow a typealias once.
    public func canonicalType(_ raw: String) -> String? {
        let nominal = SymbolTable.leadingNominal(raw)
        guard let nominal else { return nil }
        if let aliased = typeAliases[nominal] { return aliased }
        return nominal
    }

    /// The members named `name` visible on `typeName`, walking the type's own
    /// declarations then its superclass/conformed-protocol chain (so a method
    /// declared on a base class / protocol resolves on the subtype). Bounded walk
    /// (cycle-safe). Returns [] when the type is unknown.
    public func members(named name: String, on typeName: String) -> [Member] {
        var out: [Member] = []
        var seen: Set<String> = []
        var queue = [typeName]
        while let t = queue.popLast() {
            guard seen.insert(t).inserted else { continue }
            guard let decl = types[t] ?? types[canonicalType(t) ?? t] else { continue }
            if let ms = decl.membersByName[name] { out.append(contentsOf: ms) }
            for parent in decl.inherits { queue.append(parent) }
        }
        return out
    }

    /// All concrete types that conform to / inherit `protocolOrBase` (transitive).
    /// Used to bound dynamic dispatch to the real implementors of a protocol
    /// method instead of every same-named method in the project.
    public func conformers(of protocolOrBase: String) -> [String] {
        var result: [String] = []
        for (name, decl) in types where decl.kind != .protocol {
            if inheritsTransitively(name, from: protocolOrBase) { result.append(name) }
        }
        return result
    }

    private func inheritsTransitively(_ type: String, from base: String) -> Bool {
        var seen: Set<String> = []
        var queue = [type]
        while let t = queue.popLast() {
            guard seen.insert(t).inserted else { continue }
            guard let decl = types[t] else { continue }
            if decl.inherits.contains(base) { return true }
            queue.append(contentsOf: decl.inherits)
        }
        return false
    }

    /// The leading nominal identifier of a type string: `[User]` → `User`,
    /// `User?` → `User`, `Foo<Bar>` → `Foo`, `Module.Type` → `Type`, `(A,B)` → nil.
    public static func leadingNominal(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        // Strip leading `some`/`any`/`inout`.
        for prefix in ["some ", "any ", "inout "] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        // `[T]` / `[K: V]` are not nominal types we resolve members on.
        guard !s.hasPrefix("[") , !s.hasPrefix("(") else { return nil }
        // Trim trailing optional markers.
        while s.hasSuffix("?") || s.hasSuffix("!") { s = String(s.dropLast()) }
        // Take up to the first generic `<` or member `.`.
        var ident = ""
        for ch in s {
            if ch == "<" || ch == "." { break }
            if ch.isLetter || ch.isNumber || ch == "_" { ident.append(ch) }
            else { break }
        }
        // For a qualified `Module.Type`, take the LAST component instead.
        if s.contains(".") && !s.contains("<") {
            let last = s.split(separator: ".").last.map(String.init) ?? ident
            var lastIdent = ""
            for ch in last { if ch.isLetter || ch.isNumber || ch == "_" { lastIdent.append(ch) } else { break } }
            if !lastIdent.isEmpty { ident = lastIdent }
        }
        return ident.isEmpty ? nil : ident
    }
}
