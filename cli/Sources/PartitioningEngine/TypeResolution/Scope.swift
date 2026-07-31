// SPDX-License-Identifier: Apache-2.0

import Foundation
import SwiftSyntax

/// A lexical scope: locals bound so far, the enclosing type's properties, and the
/// `self` type. Locals are layered (a child scope shadows the parent) so block
/// nesting (`if`/`for`/closures) doesn't leak bindings, but we keep it simple —
/// flat with a single shadowing map is sufficient for type inference precision
/// here (over-binding a later local can only mis-type a fragment input, which the
/// splitter's liftability gate rejects, never a safety issue).
struct Scope {
    let table: SymbolTable
    let selfType: String?
    private var locals: [String: String] = [:]
    private var properties: [String: String] = [:]

    init(table: SymbolTable, selfType: String?) {
        self.table = table
        self.selfType = selfType
    }

    mutating func bind(_ name: String, type: String?) {
        guard let type, !type.isEmpty, type != "_" else { return }
        locals[name] = type
    }
    mutating func bindProperty(_ name: String, type: String) { properties[name] = type }

    func typeOf(local name: String) -> String? { locals[name] ?? properties[name] }

    /// The known type of a bare identifier in this scope: a local, then a
    /// property, then `self`, then a module-global constant.
    func typeOfIdentifier(_ name: String) -> String? {
        if name == "self" || name == "super" { return selfType }
        if let t = locals[name] { return t }
        if let t = properties[name] { return t }
        if let t = table.globals[name] { return t }
        return nil
    }

    /// All currently-bound locals + properties (for the resolved-function result).
    func allLocals() -> [String: String] {
        var out = properties
        for (k, v) in locals { out[k] = v }
        return out
    }
}
