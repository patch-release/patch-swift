// SPDX-License-Identifier: Apache-2.0

import Foundation
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftParser
import PartitioningEngine

/// Emits `_wasm.swift` and `_bridge.swift` files from a `SplitPlan`, using
/// SwiftSyntax *syntax builders* (not string templates). Agent A3 scope.
///
/// Day-7: the generated pipeline is now genuinely EXECUTABLE across the WASM ABI.
/// For every fragment whose inputs/outputs are concrete JSON-codable shapes the
/// emitter generates, alongside the plain Swift fragment function, a thin
/// `@_cdecl("<frag>")(ptr:i32, len:i32) -> i64` wrapper that:
///   * reads a JSON args envelope from `(ptr, len)` in linear memory,
///   * decodes it into a generated `Args` struct, calls the fragment,
///   * encodes the result (single value or named tuple) as JSON into a freshly
///     `patch_malloc`'d buffer, and returns the packed `(outPtr<<32)|outLen` i64.
/// The module also exports `patch_malloc`/`patch_free` (the SDK's allocator
/// convention). The native `_bridge.swift` `Patch.call(...)` is no longer a
/// `fatalError` stub — it lowers args → invokes the export via the SDK
/// (`Patch.shared.callJSON`) → decodes the typed result, so the rewired shell
/// runs the lifted logic for real. JSON is the canonical structured codec on both
/// sides (Foundation's JSONEncoder/JSONDecoder compile to WASM — see
/// poc/wasm-compilation — so the guest needs no extra codec source).
public struct CodeEmitter {
    public init() {}

    // MARK: - Symbol sanitization (Fix A + Fix C)
    //
    // OTA-eligible *operators* (`==`, `<`, `+=`, `*`, `&&`, …) and any symbol whose
    // simple name is not a valid Swift identifier cannot be used verbatim as a
    // `@_cdecl(...)` export, a `struct <name>_Args`, or a `func <name>(...)` — they
    // emit invalid Swift (`@_cdecl("==")`, `private struct ==_Args`, …) that never
    // compiles, breaking a fragment in nearly every app (triage bucket A, ~37/52
    // apps). We map every operator/punctuation symbol to a **stable, collision-free
    // identifier** (`==` → `op_eqeq`, `<` → `op_lt`, `/` → `op_slash`, …) used for
    // ALL generated Swift identifiers AND the `@_cdecl` export string AND the native
    // bridge's `Patch.call("…")` name (both sides come from this same mapping, so
    // they always agree). The REAL operator/target is still what the wrapper calls
    // inside, so behaviour is identical — only the symbol the host invokes is
    // renamed. An empty/anonymous symbol (Fix C) maps to a stable `_anon` so codegen
    // never produces a path-breaking bare `_wasm.swift` / `/`.

    private static let opCharNames: [Character: String] = [
        "=": "eq", "<": "lt", ">": "gt", "+": "plus", "-": "minus",
        "*": "star", "/": "slash", "%": "pct", "&": "amp", "|": "pipe",
        "^": "caret", "~": "tilde", "!": "bang", "?": "qmark", ".": "dot",
    ]

    /// Map an arbitrary export symbol (operator like `==`/`*`, or empty/odd name) to
    /// a valid, stable, collision-free Swift identifier used for the `@_cdecl`
    /// export, the `_Args`/`_Out` structs, the wrapper function, and the native
    /// bridge call name. A valid identifier (letter/`_` start, identifier chars
    /// only) is returned UNCHANGED (no churn). Operators → `op_<char names>`; mixed
    /// names have invalid chars spelled out so the result is unique.
    public static func sanitizedExportSymbol(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "_anon" }
        if let first = trimmed.first, (first.isLetter || first == "_"),
           trimmed.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
            return trimmed
        }
        if trimmed.allSatisfy({ opCharNames[$0] != nil }) {
            return "op_" + trimmed.compactMap { opCharNames[$0] }.joined()
        }
        var out = ""
        for ch in trimmed {
            if ch.isLetter || ch.isNumber || ch == "_" { out.append(ch) }
            else if let name = Self.opCharNames[ch] { out += "_\(name)_" }
            else { out += "_u\(String(ch.unicodeScalars.first!.value))_" }
        }
        if let first = out.first, !(first.isLetter || first == "_") { out = "_" + out }
        return out.isEmpty ? "_anon" : out
    }

    /// Filesystem-safe base for a `<base>_wasm.swift` / `<base>_bridge.swift` file
    /// from a possibly-empty/operator simple name (Fix C: a `/` base produced a
    /// path-breaking `/_wasm.swift` that crashed YPImagePicker).
    public static func sanitizedFileBase(_ raw: String) -> String { sanitizedExportSymbol(raw) }

    // MARK: - Keyword-safe struct field names (Fix S3)
    //
    // A `_Args`/`_Out` envelope FIELD name comes from the dev's param / stored-field
    // name via SwiftSyntax `.text`, which STRIPS backticks. A dev parameter or field
    // named after a Swift keyword (`default`, `where`, `repeat`, `class`, `in`, …)
    // therefore emits `let default: Int` (no backticks) — "keyword 'default' cannot
    // be used as an identifier here." This breaks the GUEST wrapper AND, via the
    // native-bridge `_Args`/`_Out` mirror, the DEVELOPER's Xcode build. We backtick-
    // escape any field name that is a reserved keyword (the JSON coding key is
    // PRESERVED because Swift's synthesized `CodingKeys` uses the unescaped property
    // name — `let `default`: Int` still serializes under the JSON key "default", so
    // both sides agree without an explicit `CodingKeys` map).

    /// Swift reserved keywords that cannot appear as a bare identifier in a
    /// `let <name>: <Type>` declaration. Contextual keywords that ARE valid bare
    /// identifiers (`get`/`set`/`some`/`any`/`async`/…) are deliberately omitted —
    /// escaping them is harmless but unnecessary, and over-escaping risks churn.
    private static let reservedKeywords: Set<String> = [
        // Declarations
        "associatedtype", "class", "deinit", "enum", "extension", "fileprivate",
        "func", "import", "init", "inout", "internal", "let", "operator", "private",
        "protocol", "public", "rethrows", "static", "struct", "subscript",
        "typealias", "var",
        // Statements
        "break", "case", "continue", "default", "defer", "do", "else",
        "fallthrough", "for", "guard", "if", "in", "repeat", "return", "switch",
        "where", "while",
        // Expressions / types
        "as", "catch", "false", "is", "nil", "super", "self", "Self", "throw",
        "throws", "true", "try",
    ]

    /// Backtick-escape `name` if it is a reserved Swift keyword, so it is valid as a
    /// bare `let <name>: <Type>` field declaration. A non-keyword name (the common
    /// case) is returned UNCHANGED. The JSON coding key is preserved by Swift's
    /// `CodingKeys` synthesis (which uses the unescaped property name).
    public static func keywordSafeFieldName(_ name: String) -> String {
        reservedKeywords.contains(name) ? "`\(name)`" : name
    }

    public struct EmittedFiles: Sendable {
        public let wasmFileName: String
        public let wasmSource: String
        public let bridgeFileName: String
        public let bridgeSource: String
        /// Export symbols the wasm file actually carries `@_cdecl` wrappers for
        /// (deterministic; the native bridge calls exactly these). Always also
        /// includes `patch_malloc`/`patch_free` when any export is present.
        public let exportSymbols: [String]
    }

    // MARK: - Pure (non-mixed) wasm-eligible function export
    //
    // A pure, wasm-eligible function (no `mixed` split) is exported wholesale:
    // the developer's function is called verbatim from a JSON (ptr,len) wrapper.

    /// A whole wasm-eligible function exported across the ABI as JSON in/out.
    public struct PureExport: Sendable {
        /// The export symbol (what the native bridge calls). Deterministic.
        public let exportName: String
        /// How to call the developer's function, e.g. `PricingEngine.checkout`.
        /// For an instance method on a value type this is the bare method name; the
        /// call is built as `_receiver.<method>(...)` using `receiverType`.
        public let callee: String
        /// Argument (label, name, type). `label == "_"` for an unlabeled param.
        public let parameters: [(label: String, name: String, type: String)]
        /// The function's return type ("" / "Void" if none).
        public let returnType: String
        /// For a pure INSTANCE method on a value type: the receiver's type name
        /// (a Codable value type bundled into the module). The wrapper decodes a
        /// `_receiver: <Type>` field from the args envelope and calls
        /// `_receiver.<method>(...)`. nil for a free / static function.
        public let receiverType: String?

        /// Fix A: fixity of an exported OPERATOR. An operator cannot be called with
        /// the labelled member syntax `Type.==(lhs:rhs:)` (invalid Swift); it must
        /// be invoked with the real operator — a binary `==` as `a == b`, a prefix
        /// `-`/`!` as `-a`, a postfix as `a…`. nil for an ordinary function.
        public enum OperatorFixity: Sendable { case infix, prefix, postfix }
        public let operatorFixity: OperatorFixity?
        /// The literal operator token (`==`, `<`, `+`, …) when this is an operator.
        public let operatorToken: String?
        /// The value type an OPERATOR is defined on (e.g. `Money` for `static func ==
        /// (lhs:rhs:)`). The dependency-closure bundler can't resolve a bare operator
        /// as a free function; the BuildPipeline bundles this TYPE + ships the
        /// operator as one of its pure members. nil for a free operator / non-op.
        public let operatorDefiningType: String?

        // MARK: - Concrete monomorphization of a GENERIC eligible function
        //
        // A `@_cdecl` export cannot itself be generic, so every generic-signature
        // function would otherwise drop. Instead we SPECIALIZE: pick a concrete
        // instantiation (e.g. `Self = [Int]`, `Element = Int`, or a free generic's
        // `T = Int`), substitute the placeholders in the parameter/return types so
        // every boundary type is ABI-codable, and emit a NON-generic `@_cdecl`
        // wrapper that calls the developer's UNCHANGED generic function at that
        // concrete type — Swift monomorphizes the call automatically. The generic
        // body itself is bundled VERBATIM into the module (Swift compiles generics to
        // WASM fine); only the thin cross-ABI wrapper is concrete. `receiverType`
        // already carries the concrete receiver (`[Int]`) for an instance/`extension
        // Sequence` method, and `parameters`/`returnType` already hold the SUBSTITUTED
        // concrete types — so the emitter is unchanged. This struct only records the
        // verbatim generic SOURCE the bundler must ship so the module is self-contained.
        public struct GenericSpecialization: Sendable {
            /// The verbatim Swift source of the generic definition to bundle into the
            /// module (the whole `extension Sequence where … { func … }` for a method,
            /// or the whole `func name<…>(…) { … }` for a free function). Emitted
            /// once, deduped by `definitionKey`.
            public let verbatimDefinition: String
            /// A stable de-dup key (so two specializations of the same generic share
            /// one bundled copy of its source).
            public let definitionKey: String
            /// Human-readable record of the chosen instantiation (for the report),
            /// e.g. `Self=[Int], Element=Int`.
            public let instantiation: String
            public init(verbatimDefinition: String, definitionKey: String, instantiation: String) {
                self.verbatimDefinition = verbatimDefinition
                self.definitionKey = definitionKey
                self.instantiation = instantiation
            }
        }
        /// Non-nil iff this export is a concrete monomorphization of a generic
        /// function (see `GenericSpecialization`). The wrapper itself is identical to
        /// any other concrete pure export; this just carries the generic body to bundle.
        public let genericSpec: GenericSpecialization?

        // MARK: - SELF-FREE instance-method lowering (receiver-less free function)
        //
        // An INSTANCE method whose body references NO `self` member — neither
        // `self.x` nor a bare instance-member reference — is a PURE FUNCTION OF ITS
        // PARAMETERS (`SettingsScreen.relativeString(from:)`: a `RelativeDateTimeFormatter`
        // over the `date` param, never `self`). Such a method WAS demoted because the
        // value-type-receiver path decoded `_receiver: <Type>` — and a SwiftUI View
        // (`@State`/`@Environment` storage) is not `Decodable`, so the guest compile
        // failed. Instead we BYPASS the receiver entirely: synthesize a standalone
        // FREE function carrying the method's verbatim body and EXPORT THAT (no
        // `_receiver` field). `callee` is the synthetic free symbol; `receiverType`
        // stays nil. The BuildPipeline ships `verbatimDefinition` into the module and
        // emits the ordinary free-function wrapper. DEMOTE-SAFE: if the body secretly
        // touches `self`/an instance member, the synthesized free function fails to
        // compile (an unbound identifier) and the convergence loop drops ONLY that
        // export — never a false negative.
        public struct SelfFreeFreeFunction: Sendable {
            /// The synthesized standalone free-function source to bundle into the
            /// module, e.g. `func __patch_sf_SettingsScreen_relativeString(from date:
            /// Date) -> String { … }`. Emitted once per export (its symbol is unique).
            public let verbatimDefinition: String
            /// The synthetic free-function symbol the wrapper calls (matches the def).
            public let symbolName: String
            public init(verbatimDefinition: String, symbolName: String) {
                self.verbatimDefinition = verbatimDefinition
                self.symbolName = symbolName
            }
        }
        /// Non-nil iff this export is a SELF-FREE instance method lowered to a
        /// receiver-less free function (see `SelfFreeFreeFunction`). When set,
        /// `receiverType` is nil and `callee` is the synthetic free symbol.
        public let selfFreeFreeFunction: SelfFreeFreeFunction?

        /// True iff `callee` names a COMPUTED PROPERTY (a `var prop: T { … }`), not a
        /// function. A property is accessed with NO call parens (`Type.prop`, not
        /// `Type.prop()`); the parameter list is always empty. (An instance-less static
        /// property on a value type — e.g. Money's `AED.code` — is a pure zero-arg value
        /// export that the function-only scanner previously skipped entirely.)
        public let isProperty: Bool

        // MARK: - Value-type T0 reconstruction (value-type receiver / arg)
        //
        // A pure INSTANCE method on a value type — or a value-type PARAMETER — can ride
        // the tiny T0 (Embedded) tier when the value type is EMBEDDED-RECONSTRUCTABLE:
        // a struct/enum-with-rawValue whose stored fields are all T0 scalars
        // (Int/Double/Bool/String) or themselves reconstructable value types. The
        // boundary value crosses as a NESTED JSON object; the T0 wrapper extracts it
        // with the `json_get_subobject` host bridge and rebuilds it field-by-field with
        // the existing scalar readers (no in-guest Foundation/Codable), then constructs
        // the value with its memberwise initializer. `ValueTypeShape` carries exactly
        // what the emitter needs to synthesize that reconstruction.
        public struct ValueTypeShape: Sendable {
            public struct Field: Sendable {
                public let name: String
                public let type: String
                /// LEVER #1 (nested Codable): when this field's TYPE is itself a
                /// flat-scalar-reconstructable value type, its reconstruction shape.
                /// nil for a scalar field (Int/Double/Bool/String) — the common case.
                /// A field whose type is neither a T0 scalar NOR a reconstructable value
                /// type leaves this nil AND fails `isReadableArg`, so the WHOLE enclosing
                /// shape is rejected (→ T2) — the nesting never silently drops a field.
                public let nestedShape: ValueTypeShape?
                public init(name: String, type: String, nestedShape: ValueTypeShape? = nil) {
                    self.name = name; self.type = type; self.nestedShape = nestedShape
                }
            }
            /// The value type's simple name (`Vector`).
            public let typeName: String
            /// Stored fields in DECLARATION (memberwise-init) order.
            public let fields: [Field]
            /// The memberwise-init argument LABELS in order. For a Swift-synthesized
            /// memberwise init these equal the field names; for a positional public
            /// init (`init(_ x, _ y, _ z)`) they are all `_` (unlabeled). nil when the
            /// reconstruction must use the field-name memberwise init.
            public let initLabels: [String]?
            public init(typeName: String, fields: [Field], initLabels: [String]? = nil) {
                self.typeName = typeName; self.fields = fields; self.initLabels = initLabels
            }
        }
        /// The receiver's reconstruction shape when `receiverType != nil` AND the
        /// receiver is embedded-reconstructable (so the instance method can ride T0).
        /// nil for a free/static export or a non-reconstructable receiver (→ T2).
        public let receiverShape: ValueTypeShape?
        /// Per-parameter reconstruction shapes for value-type ARGUMENTS, keyed by the
        /// parameter's internal name. A scalar param has no entry. When a value-type
        /// param has NO entry it is not reconstructable → the export stays T2.
        public let valueParamShapes: [String: ValueTypeShape]
        /// The RETURN value's reconstruction shape when the function returns a
        /// flat-scalar value type (a struct/enum-with-stored-scalars). When present
        /// the T0 emitter HAND-ENCODES the returned value field-by-field
        /// (`{"value":{"a":…,"b":…}}`) with NO in-guest `Encodable`/JSONEncoder — the
        /// encode-side mirror of `receiverShape`/`valueParamShapes`. This is the
        /// CODABLE-BRIDGE for a value-type return: the guest never needs the app's
        /// `Codable` conformance (which may be `#if !$Embedded`-guarded → vanishes
        /// under embedded), and the native shell decodes the canonical envelope with
        /// its REAL in-binary `Decodable`. nil for a scalar/Void/non-reconstructable
        /// return → the existing scalar T0 path or the Foundation (T2) wrapper.
        public let returnShape: ValueTypeShape?

        public init(exportName: String, callee: String,
                    parameters: [(label: String, name: String, type: String)], returnType: String,
                    receiverType: String? = nil,
                    operatorFixity: OperatorFixity? = nil, operatorToken: String? = nil,
                    operatorDefiningType: String? = nil,
                    genericSpec: GenericSpecialization? = nil,
                    selfFreeFreeFunction: SelfFreeFreeFunction? = nil,
                    isProperty: Bool = false,
                    receiverShape: ValueTypeShape? = nil,
                    valueParamShapes: [String: ValueTypeShape] = [:],
                    returnShape: ValueTypeShape? = nil) {
            self.exportName = exportName
            self.callee = callee
            self.parameters = parameters
            self.returnType = returnType
            self.receiverType = receiverType
            self.operatorFixity = operatorFixity
            self.operatorToken = operatorToken
            self.operatorDefiningType = operatorDefiningType
            self.genericSpec = genericSpec
            self.selfFreeFreeFunction = selfFreeFreeFunction
            self.isProperty = isProperty
            self.receiverShape = receiverShape
            self.valueParamShapes = valueParamShapes
            self.returnShape = returnShape
        }
    }

    /// Emit a standalone `<export>_wasm.swift` that exports `export` across the
    /// (ptr,len) ABI. The wasm compile unit must also contain the developer's
    /// source defining `callee` and its parameter/return types; the BuildPipeline
    /// copies those in. Returns the source + the export symbols.
    ///
    /// ## T0 (Embedded) is now the automatic path
    /// When the export's argument/return shapes are reducible to the **host JSON
    /// bridge** (`patch_host.json_get_i64`) — integer scalars / `Bool` — this emits
    /// an **embedded-compatible** wrapper that decodes args by calling the host
    /// bridge and hand-encodes the `{"value":N}` result, with NO in-module
    /// `import Foundation`, `JSONEncoder`/`JSONDecoder`, or `Codable` synthesis.
    /// That keeps the compile unit Embedded-safe, so the module rides **T0** (tens
    /// of KB) instead of being forced to **T2** (~57 MB) by an in-guest JSON coder.
    /// The wire format is byte-identical to the old JSON ABI (`{"a":…}` in,
    /// `{"value":N}` out), so the SDK's `callJSON`/`callPacked` + `FoundationBridge`
    /// drive it unchanged.
    ///
    /// When a shape is NOT host-JSON-reducible (a string/array/struct arg, a
    /// non-integer return) the emitter falls back to the original Foundation
    /// `JSONEncoder` wrapper (which selects T1/T2). The fallback is always correct;
    /// it only costs size.
    public func emitPureExportFile(_ export: PureExport, includeAllocator: Bool) -> (fileName: String, source: String, exports: [String]) {
        if let t0 = emitEmbeddedPureExportFile(export, includeAllocator: includeAllocator) {
            return t0
        }
        return emitFoundationPureExportFile(export, includeAllocator: includeAllocator)
    }

    /// Public entry to the Foundation (T2) JSON wrapper — used when an export's
    /// boundary carries a reconstructed value type (a struct/enum), which the T0
    /// host-scalar bridge cannot marshal. The in-module `JSONEncoder`/`JSONDecoder`
    /// (de)code the bundled `Codable` value types across the (ptr,len) ABI.
    public func emitFoundationPureExportFilePublic(_ export: PureExport, includeAllocator: Bool) -> (fileName: String, source: String, exports: [String]) {
        emitFoundationPureExportFile(export, includeAllocator: includeAllocator)
    }

    /// The set of floating-point types whose non-finite (NaN/±Inf) values would
    /// make Foundation's default `JSONEncoder` THROW (it rejects non-conforming
    /// floats), so the wrapper's `try?` yields `{}` and the SDK's required `value`
    /// field decode crashes. A top-level output of one of these types is clamped
    /// to a finite, parseable JSON number via `_patchFinite(_:)` before encoding —
    /// the exact analog of the T0 hand-encoder's non-finite guard (cli3 fix #1).
    static func isClampableFloatType(_ type: String) -> Bool {
        let bare = type.trimmingCharacters(in: .whitespaces)
        // Strip a single trailing `?` (a top-level Optional float still clamps).
        let core = bare.hasSuffix("?")
            ? String(bare.dropLast()).trimmingCharacters(in: .whitespaces)
            : bare
        // Only the stdlib float types backed by Double/Float — these are accepted
        // by the `_patchFinite` overloads with no extra import. (CGFloat would need
        // CoreGraphics; it's left to the existing `try?`-to-`{}` fallback.)
        switch core {
        case "Double", "Float", "Float64", "Float32", "TimeInterval":
            return true
        default:
            return false
        }
    }

    /// `_patchFinite(_:)` overloads: clamp a non-finite float to a VALID JSON
    /// number before it reaches `JSONEncoder` (NaN -> 0, +Inf -> greatestFinite,
    /// -Inf -> -greatestFinite). Without this, encoding a non-finite Double/Float
    /// throws, the wrapper falls back to `{}`, and the SDK's `_Out{value:Double}`
    /// decode fails on the MISSING field — crashing the OTA call. Pure stdlib;
    /// the result stays a plain JSON number the SDK's default decoder parses.
    private func finiteFloatHelperSource() -> String {
        return """
        // Clamp non-finite floats to a valid JSON number before encoding so the
        // result envelope never degrades to `{}` (which would crash the SDK decode).
        @inline(__always) private func _patchFinite(_ v: Double) -> Double {
            if v.isNaN { return 0 }
            if v.isInfinite { return v < 0 ? -Double.greatestFiniteMagnitude : Double.greatestFiniteMagnitude }
            return v
        }
        @inline(__always) private func _patchFinite(_ v: Float) -> Float {
            if v.isNaN { return 0 }
            if v.isInfinite { return v < 0 ? -Float.greatestFiniteMagnitude : Float.greatestFiniteMagnitude }
            return v
        }
        @inline(__always) private func _patchFinite(_ v: Double?) -> Double? { v.map(_patchFinite) }
        @inline(__always) private func _patchFinite(_ v: Float?) -> Float? { v.map(_patchFinite) }

        """
    }

    /// The original Foundation `JSONEncoder` wrapper (T1/T2 fallback). Retained for
    /// shapes the host-JSON bridge cannot reduce.
    private func emitFoundationPureExportFile(_ export: PureExport, includeAllocator: Bool) -> (fileName: String, source: String, exports: [String]) {
        var out = "// Auto-generated by Patch — JSON (ptr,len) ABI wrapper for \(export.callee).\n"
        out += "// Compiled to WASM (OTA-updatable). DO NOT EDIT.\n\n"
        out += "import Foundation\n\n"
        if includeAllocator { out += allocatorSource() + "\n" }
        // Non-finite float guard for the result envelope (see finiteFloatHelperSource).
        out += finiteFloatHelperSource()

        // An instance method adds a leading `_receiver: <Type>` field to the args
        // envelope (the JSON-encoded receiver value).
        var argsFields = export.parameters.map { (name: $0.name, type: $0.type) }
        if let rt = export.receiverType {
            argsFields.insert((name: "_receiver", type: rt), at: 0)
        }

        // A small FIXED TUPLE return `(A, B)` / `(x: A, y: B)` is NOT Codable as a
        // single field (a Swift tuple has no synthesized Codable), so wrapping it as
        // one `value: (A, B)` field makes the `_Out` struct fail to compile and the
        // export demotes. Instead FLATTEN the tuple into one struct field per
        // component (the same multi-output spread the mixed-fragment path already
        // uses): an UNLABELED component becomes field `_<i>` read from `_result.<i>`;
        // a LABELED component becomes field `<label>` read from `_result.<label>`.
        // (A top-level OPTIONAL tuple `(A, B)?` stays a single Codable `value` field —
        // `Optional<tuple>` isn't positionally spreadable; it rides the normal path.)
        if let comps = Self.tupleComponents(of: export.returnType) {
            out += tupleAbiWrapperSource(
                exportName: export.exportName,
                argsFields: argsFields,
                callExpr: callExpression(export),
                components: comps)
            var exports = [Self.sanitizedExportSymbol(export.exportName)]
            if includeAllocator { exports += ["patch_malloc", "patch_free"] }
            return ("\(Self.sanitizedFileBase(export.exportName))_wasm.swift", out, exports)
        }

        let outputs: [(name: String, type: String)] =
            (export.returnType.isEmpty || export.returnType == "Void")
            ? [] : [(name: "value", type: export.returnType)]
        out += abiWrapperSource(
            exportName: export.exportName,
            argsFields: argsFields,
            callExpr: callExpression(export),
            outputs: outputs)

        // The native bridge calls the SANITIZED symbol (operators → `op_*`); the
        // file name must be filesystem-safe (Fix A + Fix C).
        var exports = [Self.sanitizedExportSymbol(export.exportName)]
        if includeAllocator { exports += ["patch_malloc", "patch_free"] }
        return ("\(Self.sanitizedFileBase(export.exportName))_wasm.swift", out, exports)
    }

    /// Parse a TOP-LEVEL fixed tuple type `(A, B)` / `(x: A, y: B)` into its
    /// components (the accessor — a label or the positional index string — and the
    /// component type). Returns nil when `raw` is not a top-level tuple: a non-tuple,
    /// an optional tuple `(A, B)?` (not positionally spreadable), a single
    /// parenthesized type `(A)` (just `A` — Swift has no 1-tuple), or a degenerate
    /// shape. Commas/colons inside nested `[]`/`<>`/`()` are skipped so
    /// `(a: [Int: Int], b: Foo<X, Y>)` splits into exactly two components.
    static func tupleComponents(of raw: String) -> [(accessor: String, type: String)]? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("("), t.hasSuffix(")") else { return nil }
        // Must be a single balanced parenthesized span (reject `(A) -> (B)` etc.).
        var depth = 0
        for (i, ch) in t.enumerated() {
            if ch == "(" { depth += 1 }
            else if ch == ")" { depth -= 1; if depth == 0 && i != t.count - 1 { return nil } }
        }
        let inner = String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        if inner.isEmpty { return nil }
        // Split on TOP-LEVEL commas only.
        var parts: [String] = []
        var cur = ""
        var d = 0
        for ch in inner {
            switch ch {
            case "(", "[", "<": d += 1; cur.append(ch)
            case ")", "]", ">": d -= 1; cur.append(ch)
            case "," where d == 0: parts.append(cur); cur = ""
            default: cur.append(ch)
            }
        }
        parts.append(cur)
        // A Swift 1-tuple does not exist; `(A)` is just `A` — not a tuple.
        guard parts.count >= 2 else { return nil }
        var comps: [(accessor: String, type: String)] = []
        for (i, rawPart) in parts.enumerated() {
            let p = rawPart.trimmingCharacters(in: .whitespaces)
            guard !p.isEmpty else { return nil }
            // A labeled component `name: Type` (the label is a valid identifier and the
            // colon is at top level — a `[K: V]` element's colon is nested).
            if let label = Self.leadingTupleLabel(p) {
                let type = String(p[p.index(p.startIndex, offsetBy: label.count)...])
                    .drop(while: { $0 == " " }).dropFirst()  // drop ':'
                    .trimmingCharacters(in: .whitespaces)
                guard !type.isEmpty else { return nil }
                comps.append((accessor: label, type: type))
            } else {
                comps.append((accessor: "\(i)", type: p))
            }
        }
        return comps
    }

    /// If `part` begins with `<identifier>:` at top level (a tuple-element label),
    /// return the identifier; else nil (an unlabeled element, or a `[K: V]` whose
    /// colon is inside brackets). The label must be a plain identifier and the colon
    /// must come before any `[`/`<`/`(` so a `[String: Int]` element isn't mistaken
    /// for a label.
    private static func leadingTupleLabel(_ part: String) -> String? {
        var ident = ""
        var idx = part.startIndex
        while idx < part.endIndex {
            let ch = part[idx]
            if ch.isLetter || ch.isNumber || ch == "_" { ident.append(ch); idx = part.index(after: idx) }
            else { break }
        }
        guard !ident.isEmpty, let first = ident.first, first.isLetter || first == "_" else { return nil }
        // Skip spaces, then require a colon (not `[`/`<`/`(`/`.` which would mean the
        // identifier was the start of a type, e.g. `Foo<...>` or `Foo.Bar`).
        var j = idx
        while j < part.endIndex, part[j] == " " { j = part.index(after: j) }
        guard j < part.endIndex, part[j] == ":" else { return nil }
        return ident
    }

    /// Emit the `_Args`/`_Out` envelopes + `@_cdecl` wrapper for a TUPLE-returning
    /// export: one `_Out` field per tuple component, each read from `_result.<acc>`
    /// (a label or a positional index). Mirrors `abiWrapperSource` but spreads the
    /// returned tuple positionally/by-label instead of wrapping it as one field.
    private func tupleAbiWrapperSource(
        exportName: String,
        argsFields: [(name: String, type: String)],
        callExpr: String,
        components: [(accessor: String, type: String)]
    ) -> String {
        let sym = Self.sanitizedExportSymbol(exportName)
        let fn = "\(sym)__abi"
        let argsType = "\(sym)_Args"
        let outType = "\(sym)_Out"

        // Each component becomes a struct field. An unlabeled component's accessor is
        // a positional index ("0") — not a valid field name — so its field is `_<i>`.
        // A keyword-named labeled component (`default`, `where`, …) is backtick-escaped
        // (Fix S3); the JSON key is preserved by Swift's CodingKeys synthesis.
        func fieldName(_ acc: String) -> String {
            (acc.first?.isNumber ?? false) ? "_\(acc)" : Self.keywordSafeFieldName(acc)
        }

        var src = ""
        if argsFields.isEmpty {
            src += "private struct \(argsType): Decodable {}\n"
        } else {
            src += "private struct \(argsType): Decodable {\n"
            for f in argsFields { src += "    let \(Self.keywordSafeFieldName(f.name)): \(f.type)\n" }
            src += "}\n"
        }
        src += "private struct \(outType): Encodable {\n"
        for c in components { src += "    let \(fieldName(c.accessor)): \(c.type)\n" }
        src += "}\n"

        // A non-finite float component is clamped so JSONEncoder doesn't throw
        // (which would degrade the whole envelope to `{}` and crash the SDK decode).
        // The tuple-member READ keeps a positional accessor (`_result.0`) bare but
        // keyword-escapes a LABEL accessor (`_result.`default``) (S3).
        let init_ = components.map { c -> String in
            let accessor = (c.accessor.first?.isNumber ?? false)
                ? c.accessor : Self.keywordSafeFieldName(c.accessor)
            let read = "_result.\(accessor)"
            let v = Self.isClampableFloatType(c.type) ? "_patchFinite(\(read))" : read
            return "\(fieldName(c.accessor)): \(v)"
        }.joined(separator: ", ")
        let decodeArgs = argsFields.isEmpty
            ? "    _ = _inData  // no arguments to decode"
            : "    let _args = try! JSONDecoder().decode(\(argsType).self, from: _inData)"

        src += """

        @_cdecl("\(sym)")
        public func \(fn)(_ ptr: Int32, _ len: Int32) -> Int64 {
            let _inData: Data
            if len > 0, let _base = UnsafeRawPointer(bitPattern: Int(ptr)) {
                _inData = Data(bytes: _base, count: Int(len))
            } else {
                _inData = Data()
            }
        \(decodeArgs)
            let _result = \(callExpr)
            let _out = \(outType)(\(init_))
            let _outData = (try? JSONEncoder().encode(_out)) ?? Data("{}".utf8)
            let _outLen = _outData.count
            let _outRaw = UnsafeMutableRawPointer.allocate(byteCount: max(_outLen, 1), alignment: 8)
            _outData.withUnsafeBytes { _src in
                if let _b = _src.baseAddress, _outLen > 0 { _outRaw.copyMemory(from: _b, byteCount: _outLen) }
            }
            let _outPtr = Int(bitPattern: _outRaw)
            return (Int64(_outPtr) << 32) | Int64(_outLen)
        }

        """
        return src
    }

    /// Emit the **Embedded (T0)** host-bridge wrapper for an export, or nil if the
    /// export's shapes are not host-JSON-reducible. Uses the `patch_host`
    /// JSON/scalar bridges (via `CHost`) and no in-module Foundation/Codable.
    public func emitEmbeddedPureExportFile(_ export: PureExport, includeAllocator: Bool) -> (fileName: String, source: String, exports: [String])? {
        // FINAL size lever: a pure INSTANCE method on a value type (or a value-type
        // PARAMETER) can ride T0 when the value type is EMBEDDED-RECONSTRUCTABLE — the
        // receiver/arg crosses as a nested JSON object and is rebuilt field-by-field
        // with the `json_get_subobject` bridge + the existing scalar readers (no
        // in-guest Foundation/Codable). When the receiver/a value-type arg is NOT
        // reconstructable (Codable/Foundation/reference fields), this returns nil →
        // the Foundation (T2) wrapper decodes the Codable boundary instead (correct,
        // only larger).
        guard let recon = t0Reconstruction(for: export) else {
            // Pure-scalar fast path (no receiver, no value-type args): the original T0.
            // A flat-scalar value-type RETURN is also admitted here (the encode-side
            // mirror — hand-encoded field-by-field, no in-guest Codable) even when the
            // args are all scalar, so a plain `func decode(json: String) -> Model`
            // rides T0 instead of demoting to the Codable-dependent T2 wrapper.
            guard export.receiverType == nil else { return nil }
            let scalarArgs = export.parameters.map { (name: $0.name, type: $0.type) }
            guard scalarArgs.allSatisfy({ T0Marshalling.isReadableArg($0.type) }) else { return nil }
            guard t0ReturnIsEncodable(export) else { return nil }
            return emitT0WrapperFile(export, valueShapes: [:], includeAllocator: includeAllocator)
        }
        return emitT0WrapperFile(export, valueShapes: recon, includeAllocator: includeAllocator)
    }

    /// The return is T0-hand-encodable when it is a scalar/String/Void
    /// (`isEncodableReturn`) OR a flat-scalar VALUE-TYPE return whose `returnShape`
    /// reconstructs (encode-side) without any in-guest `Encodable`. The value-type
    /// case is the CODABLE-RETURN BRIDGE: the guest hand-encodes the stored fields
    /// into the canonical `{"value":{…}}` envelope and the native shell decodes it
    /// with the real in-binary `Decodable` — provably-correct round-trip, demote-safe
    /// (no shape → the existing scalar gate or the Foundation T2 wrapper).
    private func t0ReturnIsEncodable(_ export: PureExport) -> Bool {
        if T0Marshalling.isEncodableReturn(export.returnType) { return true }
        if let rs = export.returnShape,
           rs.typeName == export.returnType.trimmingCharacters(in: .whitespaces),
           isFullyScalarReconstructable(rs) {
            return true
        }
        return false
    }

    /// The reconstruction plan for an export that crosses one or more value types at
    /// the boundary (a receiver and/or value-type params). Returns a map from the
    /// boundary field name (`"_receiver"` or a param's internal name) to its
    /// `ValueTypeShape`, or nil when the export is NOT T0-eligible: any value-type
    /// boundary that lacks a (provided, fully-scalar-reconstructable) shape, a
    /// non-scalar-encodable return, or a scalar param that isn't host-readable. nil
    /// for a plain scalar export (the caller takes the pure-scalar fast path).
    private func t0Reconstruction(for export: PureExport) -> [String: PureExport.ValueTypeShape]? {
        // The return must be T0-hand-encodable: a scalar/Void OR a flat-scalar
        // value-type return (encode-side reconstruction via `returnShape`, no in-guest
        // Codable). Anything else (a Foundation-backed / nested-struct return) falls
        // back to the Foundation (T2) wrapper.
        guard t0ReturnIsEncodable(export) else { return nil }
        var shapes: [String: PureExport.ValueTypeShape] = [:]
        var anyValueType = false

        if let rt = export.receiverType {
            guard let shape = export.receiverShape, shape.typeName == rt,
                  isFullyScalarReconstructable(shape) else { return nil }
            shapes["_receiver"] = shape
            anyValueType = true
        }
        for p in export.parameters {
            if T0Marshalling.isReadableArg(p.type) { continue }   // scalar param — fine
            // A non-scalar param must be a reconstructable value type.
            guard let shape = export.valueParamShapes[p.name],
                  isFullyScalarReconstructable(shape) else { return nil }
            shapes[p.name] = shape
            anyValueType = true
        }
        return anyValueType ? shapes : nil
    }

    /// A value type is reconstructable at T0 when every stored field is EITHER a T0
    /// host-readable scalar (Int/Double/Bool/String) OR is itself a reconstructable
    /// value type carrying a `nestedShape` (LEVER #1: nested Codable). A field that is
    /// neither (a `Decimal`/array/Foundation-backed/reference type) has no scalar form
    /// and no nested shape → the WHOLE shape is rejected → T2 (no field is ever
    /// silently dropped). Recursion is bounded by the shape graph already being finite
    /// (cycles are cut at shape-build time in `valueTypeShape`).
    private func isFullyScalarReconstructable(_ shape: PureExport.ValueTypeShape) -> Bool {
        guard !shape.fields.isEmpty else { return false }
        return shape.fields.allSatisfy { f in
            if T0Marshalling.isReadableArg(f.type) { return true }
            // A non-scalar field MUST carry a reconstructable nested shape whose type
            // matches the field's declared type.
            guard let nested = f.nestedShape,
                  nested.typeName == f.type.trimmingCharacters(in: .whitespaces) else { return false }
            return isFullyScalarReconstructable(nested)
        }
    }

    /// Emit the T0 wrapper file. `valueShapes` maps a boundary field name
    /// (`"_receiver"` or a param internal name) to its reconstruction shape; an empty
    /// map is the pure-scalar path.
    private func emitT0WrapperFile(_ export: PureExport,
                                   valueShapes: [String: PureExport.ValueTypeShape],
                                   includeAllocator: Bool) -> (fileName: String, source: String, exports: [String])? {
        var out = "// Auto-generated by Patch — Embedded (T0) host-bridge ABI wrapper for \(export.callee).\n"
        out += "// Compiled with the EMBEDDED WASM SDK (no Foundation/ICU in the module).\n"
        if valueShapes.isEmpty {
            out += "// Scalar args are read via the patch_host JSON bridge and the result is\n"
            out += "// hand-encoded as {\"value\":N} with no in-module JSON coder or derived\n"
            out += "// conformances, so this stays Embedded-compatible (T0, tens of KB). DO NOT EDIT.\n\n"
        } else {
            out += "// A value-type receiver/arg crosses as a nested JSON object and is rebuilt\n"
            out += "// field-by-field via the json_get_subobject bridge + scalar readers (no\n"
            out += "// in-guest Foundation/Codable), so the instance-method math rides T0. DO NOT EDIT.\n\n"
        }
        // `import CHost` exposes the flat host imports; the Swift bridge helpers
        // (patchJSONGetI64 etc.) come from CHeaderBridge's _patch_host_bridge.swift.
        out += "import CHost\n\n"
        // Fix D: the @_cdecl allocator (patch_malloc/patch_free) is a once-per-module
        // C export → gate on includeAllocator. But the T0 marshalling helpers
        // (_patchReadArgs/_patchEncodeResult) are now `private` (file-scoped) and
        // emitted UNCONDITIONALLY for EVERY T0 file: a 2nd T0 export in a module
        // previously referenced them without them being emitted (they only went into
        // the first/allocator file) and failed `cannot find '_patchReadArgs'`.
        if includeAllocator { out += embeddedAllocatorSource() + "\n" }
        out += t0JSONHelpersSource() + "\n"

        // A value-type RETURN is hand-encoded field-by-field (the encode-side mirror
        // of the value-type arg reconstruction) ONLY when the return is NOT already a
        // T0 scalar — `t0ReturnIsEncodable` may be true for both. Pin to the
        // value-type case here so a scalar return keeps its existing hand-encoder.
        let returnShape: PureExport.ValueTypeShape? =
            T0Marshalling.isEncodableReturn(export.returnType) ? nil : export.returnShape
        out += t0AbiWrapperSource(
            exportName: export.exportName,
            argsFields: export.parameters.map { (name: $0.name, type: $0.type) },
            callExpr: callExpression(export),
            returnType: export.returnType,
            valueShapes: valueShapes,
            hasReceiver: export.receiverType != nil,
            returnShape: returnShape)

        // The native bridge calls the SANITIZED symbol; file name filesystem-safe.
        var exports = [Self.sanitizedExportSymbol(export.exportName)]
        if includeAllocator { exports += ["patch_malloc", "patch_free"] }
        return ("\(Self.sanitizedFileBase(export.exportName))_wasm.swift", out, exports)
    }

    private func callExpression(_ export: PureExport) -> String {
        // Fix A: an exported OPERATOR is invoked with the REAL operator (`a == b`),
        // not the invalid labelled member form `Type.==(lhs:rhs:)`.
        if let fixity = export.operatorFixity, let op = export.operatorToken {
            // The `_args` field read is keyword-escaped to match the (escaped) envelope
            // field name (S3).
            let a = export.parameters.map { "_args.\(Self.keywordSafeFieldName($0.name))" }
            switch fixity {
            case .infix where a.count == 2:   return "\(a[0]) \(op) \(a[1])"
            case .prefix where a.count == 1:  return "\(op)\(a[0])"
            case .postfix where a.count == 1: return "\(a[0])\(op)"
            default:                          return "\(export.callee)(\(a.joined(separator: ", ")))"
            }
        }
        let args = export.parameters.map { p -> String in
            let r = "_args.\(Self.keywordSafeFieldName(p.name))"
            return p.label == "_" ? r : "\(p.label): \(r)"
        }.joined(separator: ", ")
        if export.receiverType != nil {
            // Pure instance method on a value type: the receiver is decoded as the
            // `_receiver` arg field and the method is invoked on it.
            if export.isProperty { return "_args._receiver.\(export.callee)" }
            return "_args._receiver.\(export.callee)(\(args))"
        }
        // A computed property is accessed with no call parens (`Type.prop`).
        if export.isProperty { return export.callee }
        return "\(export.callee)(\(args))"
    }

    // MARK: - SwiftUI value-lift export (P1)
    //
    // A pure VALUE member of a (per-member-freed) SwiftUI view type — a design
    // token / label / value helper — is lifted whole. Its *getter body* becomes a
    // standalone WASM function `_pv_<Type>_<member>(...)` and the native shell
    // keeps a thin getter shim whose body is `Patch.value("Type.member")` /
    // `Patch.call("Type.member", inputs)`. The native `body` is untouched, so the
    // shell fingerprint is stable across value-only OTA edits (font 17→22, label
    // "Hi"→"Welcome back" ship by changing ONLY the WASM `_pv_` function).
    //
    // CGFloat is not a WASM scalar: it crosses the ABI as `Double` and is wrapped
    // back to `CGFloat` at the (native) use site. Color tokens lifted as a value
    // are lifted as the *value the Color is built from* (a hex/RGBA string or the
    // asset name) — the `Color(...)` construction itself stays native (it is
    // `mustStayNative`), so a member that constructs a Color is never freed.

    /// A lifted SwiftUI value member: the WASM-side `_pv_` function (carrying the
    /// original getter body) plus everything needed to emit the native getter shim.
    public struct ValueExport: Sendable {
        /// The enclosing view type, e.g. `ProfileCard`.
        public let typeName: String
        /// The member name, e.g. `primaryFontSize` or `badgeLabel`.
        public let memberName: String
        /// Whether the member is a computed property (no inputs) or a method.
        public let isMethod: Bool
        /// Parameters (label, internal name, ABI type). Empty for a property.
        /// `abiType` is the type as it crosses the JSON ABI (CGFloat → Double).
        public let parameters: [(label: String, name: String, declType: String, abiType: String)]
        /// The member's declared Swift return type (e.g. `CGFloat`, `String`).
        public let returnType: String
        /// The ABI return type (CGFloat → Double, else == returnType).
        public let abiReturnType: String
        /// The original getter/method body statements (verbatim Swift).
        public let bodyStatements: [String]

        public init(
            typeName: String, memberName: String, isMethod: Bool,
            parameters: [(label: String, name: String, declType: String, abiType: String)],
            returnType: String, abiReturnType: String, bodyStatements: [String]
        ) {
            self.typeName = typeName
            self.memberName = memberName
            self.isMethod = isMethod
            self.parameters = parameters
            self.returnType = returnType
            self.abiReturnType = abiReturnType
            self.bodyStatements = bodyStatements
        }

        /// The dotted value-table key the native shim reads, e.g. `ProfileCard.primaryFontSize`.
        public var key: String { "\(typeName).\(memberName)" }
        /// The WASM export / function symbol, e.g. `_pv_ProfileCard_primaryFontSize`.
        public var exportName: String { "_pv_\(typeName)_\(memberName)" }
    }

    /// Map a Swift value type to its JSON-ABI type. `CGFloat` crosses as `Double`
    /// (it is not a WASM scalar); everything else is unchanged. Only confidently
    /// liftable scalar/string value types are accepted upstream, so this is a
    /// narrow, safe mapping.
    public static func abiType(for swiftType: String) -> String {
        let t = swiftType.trimmingCharacters(in: .whitespaces)
        return t == "CGFloat" ? "Double" : t
    }

    /// Whether the ABI type differs from the declared type (so the shim must wrap
    /// the value back, e.g. `CGFloat(...)`). Today only CGFloat needs wrapping.
    private func needsCGFloatWrap(_ export: ValueExport) -> Bool {
        export.returnType.trimmingCharacters(in: .whitespaces) == "CGFloat"
    }

    /// Emit a standalone `_pv_<Type>_<member>_wasm.swift` defining the `_pv_`
    /// function (original body) + its JSON (ptr,len) `@_cdecl` ABI wrapper. The
    /// developer's value-typed inputs (if any concrete user types) must be Codable;
    /// scalars/strings always are. Returns the source + export symbols.
    public func emitValueExportFile(_ export: ValueExport, includeAllocator: Bool) -> (fileName: String, source: String, exports: [String]) {
        var out = "// Auto-generated by Patch (SwiftUI value-lift) — pure value member\n"
        out += "// \(export.key) lifted from a SwiftUI view. Compiled to WASM and\n"
        out += "// OTA-updatable: changing the returned value here (e.g. 17 → 22,\n"
        out += "// \"Hi\" → \"Welcome back\") ships OTA because the native shell only reads\n"
        out += "// it via Patch.value(...)/Patch.call(...). DO NOT EDIT BY HAND.\n\n"
        out += "import Foundation\n\n"
        if includeAllocator { out += allocatorSource() + "\n" }
        // Non-finite float guard for the result envelope (CGFloat crosses as Double).
        out += finiteFloatHelperSource()

        // The `_pv_` function: original body, params at their ABI types (CGFloat →
        // Double so it crosses the boundary; the body reads them as the numeric
        // value just the same). A computed property becomes a no-arg function.
        out += valuePVFunctionSource(export) + "\n\n"

        // JSON (ptr,len) ABI wrapper calling the `_pv_` function.
        let outputs: [(name: String, type: String)] =
            (export.abiReturnType.isEmpty || export.abiReturnType == "Void")
            ? [] : [(name: "value", type: export.abiReturnType)]
        out += abiWrapperSource(
            exportName: export.exportName,
            argsFields: export.parameters.map { (name: $0.name, type: $0.abiType) },
            callExpr: valuePVCallExpr(export),
            outputs: outputs)

        var exports = [export.exportName]
        if includeAllocator { exports += ["patch_malloc", "patch_free"] }
        return ("\(export.exportName)_wasm.swift", out, exports)
    }

    /// The `_pv_` free function carrying the original member body. A keyword-named
    /// param binding is backtick-escaped (S3) — the body references it by the same
    /// (escaped) spelling.
    private func valuePVFunctionSource(_ export: ValueExport) -> String {
        let params = export.parameters.map { "_ \(Self.keywordSafeFieldName($0.name)): \($0.abiType)" }
            .joined(separator: ", ")
        let ret = (export.abiReturnType.isEmpty || export.abiReturnType == "Void")
            ? "" : " -> \(export.abiReturnType)"
        let body = export.bodyStatements.map { "    " + $0 }.joined(separator: "\n")
        return "func \(export.exportName)(\(params))\(ret) {\n\(body)\n}"
    }

    private func valuePVCallExpr(_ export: ValueExport) -> String {
        let args = export.parameters.map { "_args.\(Self.keywordSafeFieldName($0.name))" }.joined(separator: ", ")
        return "\(export.exportName)(\(args))"
    }

    /// Emit the native getter SHIM for one value member: a getter/method whose body
    /// is a `Patch.value`/`Patch.call` lookup. These shims are what replace the
    /// original member bodies in the native shell; the member SIGNATURES are frozen
    /// (so the shell fingerprint is stable) while the value rides OTA via WASM.
    ///
    /// This emits the member declaration only (the caller splices it into the
    /// view's `_bridge.swift`); the SDK provides `PatchSDK.Patch.value/.call`.
    public func emitValueMemberShim(_ export: ValueExport) -> String {
        let wrap = needsCGFloatWrap(export)
        if export.isMethod {
            let params = export.parameters.map { p -> String in
                let n = Self.keywordSafeFieldName(p.name)
                return p.label == "_" ? "_ \(n): \(p.declType)" : "\(p.label) \(n): \(p.declType)"
            }.joined(separator: ", ")
            // Args struct mirrors the WASM `_Args` envelope (ABI types). The struct-init
            // label is keyword-escaped to match the envelope field name (S3).
            let argsInit = export.parameters.map { "\(Self.keywordSafeFieldName($0.name)): \(abiArg($0))" }.joined(separator: ", ")
            let call = "Patch.call(\"\(export.key)\", \(export.exportName)_Args(\(argsInit)), returning: \(export.exportName)_Out.self).value"
            let expr = wrap ? "CGFloat(\(call))" : call
            return "    func \(export.memberName)(\(params)) -> \(export.returnType) { \(expr) }"
        } else {
            let call = "Patch.value(\"\(export.key)\", returning: \(export.exportName)_Out.self).value"
            let expr = wrap ? "CGFloat(\(call))" : call
            return "    var \(export.memberName): \(export.returnType) { \(expr) }"
        }
    }

    /// Render a method argument at its ABI type (CGFloat → Double conversion). The
    /// param read is keyword-escaped to match its (escaped) declaration (S3).
    private func abiArg(_ p: (label: String, name: String, declType: String, abiType: String)) -> String {
        let n = Self.keywordSafeFieldName(p.name)
        if p.declType.trimmingCharacters(in: .whitespaces) == "CGFloat", p.abiType == "Double" {
            return "Double(\(n))"
        }
        return n
    }

    /// Emit a complete standalone `<Type>_values_bridge.swift` aggregating the
    /// native shims for every lifted value member of one type, plus the private
    /// JSON envelopes + the `Patch` runtime shim. This is the file whose
    /// fingerprint CI locks; its member signatures are frozen.
    public func emitValueBridgeFile(typeName: String, exports: [ValueExport]) -> (fileName: String, source: String) {
        var envelopes = ""
        for e in exports { envelopes += valueEnvelopes(for: e) + "\n" }
        let shims = exports.map { emitValueMemberShim($0) }.joined(separator: "\n")
        let memberList = exports.map { "//   \($0.key)\($0.isMethod ? "(...)" : "")" }.joined(separator: "\n")

        let source = """
        // Auto-generated by Patch (SwiftUI value-lift) — native value shims for \(typeName).
        // Stays in the App Store binary. DO NOT EDIT. The member SIGNATURES below
        // are frozen — the shell fingerprint locks them — while each VALUE is read
        // from the OTA WASM module via Patch.value/.call. The view's `body` and all
        // view-DSL members are unchanged (kept verbatim in the original source).
        //
        // Lifted value members (read OTA from WASM):
        \(memberList)

        import Foundation
        import PatchSDK
        #if canImport(CoreGraphics)
        import CoreGraphics
        #endif

        \(envelopes)extension \(typeName) {
        \(shims)
        }

        /// Patch runtime shim — resolves a lifted SwiftUI value through the active
        /// WASM module via the SDK (cached per body pass). `Patch.value` reads a
        /// no-input value; `Patch.call` invokes a value helper with inputs.
        enum Patch {
            static func value<R: Decodable>(_ key: String, returning: R.Type) -> R {
                return try! PatchSDK.Patch.shared.valueJSON(key, returning: R.self)
            }
            static func call<A: Encodable, R: Decodable>(_ key: String, _ args: A, returning: R.Type) -> R {
                return try! PatchSDK.Patch.shared.callValueJSON(key, args, returning: R.self)
            }
        }
        """
        return ("\(typeName)_values_bridge.swift", source)
    }

    /// Private JSON envelopes the value shim uses (mirrors the WASM `_Args`/`_Out`).
    private func valueEnvelopes(for e: ValueExport) -> String {
        let argsType = "\(e.exportName)_Args"
        let outType = "\(e.exportName)_Out"
        var s = ""
        if e.parameters.isEmpty {
            s += "private struct \(argsType): Encodable {}\n"
        } else {
            s += "private struct \(argsType): Encodable {\n"
            for p in e.parameters { s += "    let \(Self.keywordSafeFieldName(p.name)): \(p.abiType)\n" }
            s += "}\n"
        }
        if e.abiReturnType.isEmpty || e.abiReturnType == "Void" {
            s += "private struct \(outType): Decodable {}\n"
        } else {
            s += "private struct \(outType): Decodable {\n"
            s += "    let value: \(e.abiReturnType)\n"
            s += "}\n"
        }
        return s
    }

    // MARK: - Entry

    public func emit(_ plan: SplitPlan, includeAllocator: Bool = true) -> EmittedFiles {
        let rawBase = plan.originalSimpleName.split(separator: "(").first.map(String.init)
            ?? plan.originalSimpleName
        // Fix A + Fix C: sanitize so an operator-named (`==`) or empty/anonymous
        // mixed function never produces an invalid `==_wasm.swift` or a path-breaking
        // bare `_wasm.swift` (which crashed YPImagePicker: a `/` base resolved to a
        // missing folder). Fragment EXPORT symbols are already valid `_sp_…`
        // identifiers; this fixes the FILE name + bridge type name.
        let base = Self.sanitizedFileBase(rawBase)
        let (wasm, exports) = emitWasmFile(plan, includeAllocator: includeAllocator)
        return EmittedFiles(
            wasmFileName: "\(base)_wasm.swift",
            wasmSource: wasm,
            bridgeFileName: "\(base)_bridge.swift",
            bridgeSource: emitBridgeFile(plan),
            exportSymbols: exports
        )
    }

    // MARK: - WASM file (pure fragments + @_cdecl ABI wrappers)

    private func emitWasmFile(_ plan: SplitPlan, includeAllocator: Bool = true) -> (source: String, exports: [String]) {
        let source = SourceFileSyntax {
            for fragment in plan.pureFragments {
                DeclSyntax(makeFragmentFunction(fragment))
            }
        }
        let header = "// Auto-generated by Patch — pure logic extracted from \(plan.originalID).\n"
            + "// Compiled to WASM (OTA-updatable). DO NOT EDIT.\n\n"
            + "import Foundation\n\n"

        // Append a JSON (ptr,len) ABI wrapper for every fragment whose inputs and
        // outputs are concrete JSON-codable shapes. A fragment with a generic
        // (`_`-inferred) input/output cannot be JSON-decoded, so it ships as a
        // plain (un-exported) function only — never executable across the ABI, but
        // it still type-checks/compiles (and the convergence loop / classifier
        // keeps such cases native).
        var exports: [String] = []
        var abi = ""
        var firstWrapper = true
        for fragment in plan.pureFragments where abiEligible(fragment) {
            if firstWrapper {
                // The allocator is emitted once per module; the BuildPipeline passes
                // `includeAllocator: false` for all but the first shipped wasm file.
                abi = includeAllocator ? "\n" + allocatorSource() + "\n" : "\n"
                // Non-finite float guard for the result envelopes (emitted once,
                // alongside the first wrapper, so float fragment outputs are clamped).
                abi += finiteFloatHelperSource()
                firstWrapper = false
            }
            abi += abiWrapperSource(
                exportName: fragment.name,
                argsFields: fragment.inputs.map { (name: $0.name, type: $0.type) },
                callExpr: fragmentCallExpr(fragment),
                outputs: fragment.outputs.map { (name: $0.name, type: $0.type) })
            exports.append(fragment.name)
        }
        if !exports.isEmpty { exports += ["patch_malloc", "patch_free"] }

        return (header + source.formatted().description + "\n" + abi, exports)
    }

    /// A fragment is ABI-eligible iff every input and output has a concrete
    /// (non-generic `_`) type (so it can be JSON (de)coded).
    private func abiEligible(_ fragment: SplitPlan.PureFragment) -> Bool {
        fragment.inputs.allSatisfy { $0.type != "_" } && fragment.outputs.allSatisfy { $0.type != "_" }
    }

    /// How to call a fragment from its ABI wrapper: `_sp_x_compute(_args.a, _args.b)`.
    /// The `_args` field read is keyword-escaped to match the (escaped) envelope (S3).
    private func fragmentCallExpr(_ fragment: SplitPlan.PureFragment) -> String {
        let args = fragment.inputs.map { "_args.\(Self.keywordSafeFieldName($0.name))" }.joined(separator: ", ")
        return "\(fragment.name)(\(args))"
    }


    // MARK: - T0 (Embedded) host-bridge ABI wrapper synthesis
    //
    // The proven module-size winner (research/module-size/SYNTHESIS.md, demo's
    // OTAModule-Embedded): compile the OTA patch with the EMBEDDED WASM SDK (no
    // Foundation/ICU → tens of KB) and marshal across the boundary via the native
    // shell's real Foundation through the `patch_host` host bridge. The general
    // auto-codegen used to emit an in-guest `JSONEncoder`/`JSONDecoder` wrapper,
    // which `import Foundation` + Codable synthesis forces to T2 (~57 MB). This
    // path emits an Embedded-compatible wrapper instead: integer/Bool scalars are
    // read out of the JSON arg blob via `patch_host.json_get_i64`, and the result
    // is hand-encoded as `{"value":N}` (an embedded-safe Int64→ASCII), so the
    // compile unit needs no in-module JSON coder and rides T0.

    /// Decides whether an export's I/O shapes can be marshalled purely through the
    /// host JSON bridge (so the wrapper is Embedded-compatible). Today: every arg
    /// is an integer scalar or `Bool` (read via `json_get_i64`), and the return is
    /// an integer scalar, `Bool`, or Void (hand-encoded as `{"value":N}`). Anything
    /// else (string/array/struct/Double) falls back to the Foundation wrapper.
    enum T0Marshalling {
        /// Integer scalar types crossing the bridge as the host's i64 field value.
        static let integerScalars: Set<String> = [
            "Int", "Int8", "Int16", "Int32", "Int64",
            "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
        ]
        static func isIntegerScalar(_ t: String) -> Bool {
            integerScalars.contains(t.trimmingCharacters(in: .whitespaces))
        }
        /// UNSIGNED integer scalars. These must NOT be encoded via `Int64(_result)`
        /// — a `UInt`/`UInt64` value greater than `Int64.max` traps that conversion
        /// at runtime (crashing the module), and `UInt32(...)` likewise overflows
        /// the value's high bits. They are encoded through the dedicated
        /// `_patchEncodeResult(_ value: UInt64)` overload (unsigned base-10), so the
        /// JSON `{"value":N}` carries the true magnitude the SDK decodes back.
        static let unsignedScalars: Set<String> = [
            "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
        ]
        static func isUnsignedScalar(_ t: String) -> Bool {
            unsignedScalars.contains(t.trimmingCharacters(in: .whitespaces))
        }
        static func isBool(_ t: String) -> Bool {
            t.trimmingCharacters(in: .whitespaces) == "Bool"
        }
        // research/foundation-bridges: widen the T0-marshallable set beyond int+Bool.
        // String rides the json_get_string / packed-string ABI; Double/Float ride
        // json_get_f64 (the Double's IEEE-754 bit-pattern). Custom struct/enum/
        // array/dict boundaries stay T2.
        //
        // NOTE on Data: `Data` is a Foundation type with NO embedded-Swift form, so
        // a `Data` boundary CANNOT compile at T0 (the guest has no `import
        // Foundation`). Honoring the zero-false-negative invariant, `Data` is left
        // to the Foundation (T2) wrapper rather than emitting a T0 fragment that
        // would fail to compile. String/Double are body-safe (pure stdlib) and the
        // bulk of the unlock (1,858 of 1,960 fragments per the FINDINGS analysis).
        static func isString(_ t: String) -> Bool {
            t.trimmingCharacters(in: .whitespaces) == "String"
        }
        /// Double-family scalars read via json_get_f64 (the bit-pattern i64).
        static let floatScalars: Set<String> = ["Double", "Float", "CGFloat", "TimeInterval"]
        static func isFloatScalar(_ t: String) -> Bool {
            floatScalars.contains(t.trimmingCharacters(in: .whitespaces))
        }
        /// A type readable from a top-level JSON field via a host bridge:
        /// int/Bool (json_get_i64), String (json_get_string), Double/Float
        /// (json_get_f64).
        static func isReadableArg(_ t: String) -> Bool {
            isIntegerScalar(t) || isBool(t) || isString(t) || isFloatScalar(t)
        }
        /// A type the result can be hand-encoded into `{"value":<...>}` with no
        /// in-module Foundation: int/Bool/Double/Float (numeric/literal forms) and
        /// String (the embedded-safe JSON string escaper).
        static func isEncodableReturn(_ t: String) -> Bool {
            let tt = t.trimmingCharacters(in: .whitespaces)
            return tt.isEmpty || tt == "Void" || isIntegerScalar(tt) || isBool(tt)
                || isString(tt) || isFloatScalar(tt)
        }
        static func isEligible(args: [(name: String, type: String)], returnType: String) -> Bool {
            args.allSatisfy { isReadableArg($0.type) } && isEncodableReturn(returnType)
        }
    }

    /// The module's SHARED runtime file: the single `patch_malloc`/`patch_free`
    /// allocator for the whole compile unit. Lives in a support source that is
    /// always present (never a demotable candidate), so demoting any wrapper file
    /// can never strip the allocator from the module. Emits the Foundation
    /// allocator (the corpus's value-type boundaries force the T2 Foundation tier;
    /// it also compiles fine at T1). Exports: `patch_malloc`, `patch_free`.
    public func emitModuleRuntimeFile() -> (fileName: String, source: String, exports: [String]) {
        let src = """
        // Auto-generated by Patch — shared module runtime (single allocator for the
        // whole WASM compile unit). DO NOT EDIT.
        import Foundation

        \(allocatorSource())
        """
        return ("_PatchRuntime.swift", src, ["patch_malloc", "patch_free"])
    }

    /// BREAKTHROUGH #9 — the EMBEDDED (T0) variant of the shared module runtime:
    /// the single `patch_malloc`/`patch_free` allocator with NO `import Foundation`
    /// (the embedded SDK has no Foundation module). Used by the real-source T0 path
    /// so the whole compile unit stays Embedded-compatible — the wrappers carry no
    /// in-module Foundation, and this shared allocator file must not reintroduce it
    /// (a single `import Foundation` in any source poisons the whole T0 compile).
    /// Identical export contract to `emitModuleRuntimeFile`.
    public func emitEmbeddedModuleRuntimeFile() -> (fileName: String, source: String, exports: [String]) {
        let src = """
        // Auto-generated by Patch — shared module runtime (single allocator for the
        // whole WASM compile unit), EMBEDDED (T0) — no Foundation. DO NOT EDIT.

        \(embeddedAllocatorSource())
        """
        return ("_PatchRuntime.swift", src, ["patch_malloc", "patch_free"])
    }

    /// The Embedded-mode guest allocator. Embedded `@_cdecl` may return a raw
    /// pointer directly (matches the proven demo module); the host treats the i32
    /// pointer the same way.
    private func embeddedAllocatorSource() -> String {
        """
        // Guest allocator (Embedded) — the host writes argument blobs into these
        // buffers and reads result blobs back out (the SDK's malloc/free ABI).
        @_cdecl("patch_malloc")
        public func patch_malloc(_ size: Int32) -> UnsafeMutableRawPointer? {
            UnsafeMutableRawPointer.allocate(byteCount: Int(max(size, 1)), alignment: 8)
        }

        @_cdecl("patch_free")
        public func patch_free(_ ptr: Int32) {
            UnsafeMutableRawPointer(bitPattern: Int(ptr))?.deallocate()
        }
        """
    }

    /// Embedded-safe JSON marshalling helpers (no Foundation): read the arg blob
    /// from guest memory into `[UInt8]`, and hand-encode `{"value":N}` / `{}` into
    /// a freshly `patch_malloc`'d buffer, returning the packed `(ptr<<32)|len` i64.
    /// `_patchEncodeResult` is the one place the result envelope is built; the
    /// integer→ASCII is a tiny embedded-safe routine (no `String(Int)` reflection
    /// concerns — plain stdlib, which Embedded supports).
    /// Fix D: these helpers are now `private` (file-scoped) and emitted into EVERY
    /// T0 wrapper file (not just the first/allocator file) — `private` lets each
    /// file own its copy with no cross-file duplicate-symbol conflict, exactly like
    /// the per-file `private struct _Args`/`_Out`. (Previously `@inlinable` at file
    /// scope, emitted only with the allocator, so a 2nd T0 export failed `cannot
    /// find '_patchReadArgs' in scope`.)
    private func t0JSONHelpersSource() -> String {
        """
        // Read the (ptr,len) argument blob into a byte buffer the host JSON bridge
        // can parse. Empty when len == 0. (Binds the pointer as UInt8 directly so
        // no `.self` metatype is needed — embedded-safe, matches the demo module.)
        // `private` so every T0 file may carry its own copy (no linkage conflict).
        private func _patchReadArgs(_ ptr: Int32, _ len: Int32) -> [UInt8] {
            guard len > 0, let base = UnsafePointer<UInt8>(bitPattern: Int(ptr)) else { return [] }
            return Array(UnsafeBufferPointer(start: base, count: Int(len)))
        }

        // Pack a finished JSON `[UInt8]` into a freshly allocated result buffer and
        // return the packed `(ptr<<32)|len` i64. The one place the result blob is
        // allocated, shared by every `_patchEncodeResult` overload.
        private func _patchPackJSON(_ json: [UInt8]) -> Int64 {
            let outLen = json.count
            let raw = UnsafeMutableRawPointer.allocate(byteCount: max(outLen, 1), alignment: 8)
            json.withUnsafeBufferPointer { src in
                if let b = src.baseAddress { raw.copyMemory(from: b, byteCount: outLen) }
            }
            let outPtr = Int(bitPattern: raw)
            return (Int64(outPtr) << 32) | Int64(outLen)
        }

        // Hand-encode `{"value":<int>}` (or `{}` for Void) — embedded-safe, no
        // in-module JSON coder. Int64 base-10 formatting via the stdlib.
        private func _patchEncodeResult(_ value: Int64?) -> Int64 {
            var json: [UInt8]
            if let value {
                json = Array("{\\"value\\":".utf8)
                json.append(contentsOf: Array(String(value).utf8))
                json.append(UInt8(ascii: "}"))
            } else {
                json = Array("{}".utf8)
            }
            return _patchPackJSON(json)
        }

        // Hand-encode `{"value":<unsigned int>}` — embedded-safe. An UNSIGNED
        // return (UInt/UInt64) whose value exceeds Int64.max cannot ride the Int64
        // overload (`Int64(_result)` traps); this formats the full unsigned
        // magnitude in base-10 so the JSON carries the true value.
        private func _patchEncodeResult(_ value: UInt64) -> Int64 {
            var json = Array("{\\"value\\":".utf8)
            json.append(contentsOf: Array(String(value).utf8))
            json.append(UInt8(ascii: "}"))
            return _patchPackJSON(json)
        }

        // research/foundation-bridges: embedded-safe JSON string escaper (no
        // Foundation). Escapes backslash (0x5C), quote (0x22), and the
        // JSON-mandatory control chars so a String result can be hand-encoded into
        // {"value":"..."}. Byte constants avoid char-literal escaping in the guest.
        private func _patchJSONEscape(_ s: String) -> [UInt8] {
            let bs: UInt8 = 0x5C   // backslash
            let qt: UInt8 = 0x22   // double-quote
            var out: [UInt8] = []
            for b in s.utf8 {
                switch b {
                case bs:   out.append(bs); out.append(bs)
                case qt:   out.append(bs); out.append(qt)
                case 0x08: out.append(bs); out.append(UInt8(ascii: "b"))
                case 0x09: out.append(bs); out.append(UInt8(ascii: "t"))
                case 0x0A: out.append(bs); out.append(UInt8(ascii: "n"))
                case 0x0C: out.append(bs); out.append(UInt8(ascii: "f"))
                case 0x0D: out.append(bs); out.append(UInt8(ascii: "r"))
                case 0 ..< 0x20:
                    // \\u00XX for the remaining control characters.
                    let hex = Array("0123456789abcdef".utf8)
                    out.append(bs); out.append(UInt8(ascii: "u"))
                    out.append(UInt8(ascii: "0")); out.append(UInt8(ascii: "0"))
                    out.append(hex[Int(b >> 4)]); out.append(hex[Int(b & 0x0F)])
                default: out.append(b)
                }
            }
            return out
        }

        // Hand-encode `{"value":"<escaped string>"}` — embedded-safe.
        private func _patchEncodeResult(_ value: String) -> Int64 {
            var json = Array("{\\"value\\":\\"".utf8)
            json.append(contentsOf: _patchJSONEscape(value))
            json.append(UInt8(ascii: "\\""))
            json.append(UInt8(ascii: "}"))
            return _patchPackJSON(json)
        }

        // Embedded-safe finite-clamped JSON number bytes for a Double (shared by the
        // scalar `_patchEncodeResult(Double)` and the value-type object encoder). JSON
        // has no NaN/±Inf, so clamp: NaN -> 0, +Inf -> greatestFiniteMagnitude,
        // -Inf -> -greatestFiniteMagnitude. Pure stdlib (no Foundation).
        private func _patchEncodeFiniteNumber(_ value: Double) -> [UInt8] {
            if value.isNaN { return Array("0".utf8) }
            if value.isInfinite {
                return Array((value < 0 ? "-1.7976931348623157e+308" : "1.7976931348623157e+308").utf8)
            }
            return Array("\\(value)".utf8)
        }

        // Hand-encode `{"value":<decimal>}` for a Double/Float — stdlib `"\\(d)"` is
        // embedded-safe and emits a valid JSON number for FINITE values.
        //
        // JSON has NO representation for NaN / ±Infinity, and `"\\(Double.nan)"` /
        // `"\\(Double.infinity)"` produce the bare tokens `nan` / `inf` — which are
        // NOT valid JSON. Emitting them ships a module whose result blob the SDK's
        // standard JSON parser CANNOT read at all (total parse failure, not just a
        // wrong number), so a T0 export returning a Double/Float/CGFloat that happens
        // to be non-finite at runtime corrupts the OTA call. Clamp the non-finite
        // cases to a VALID, parseable JSON number so the module never emits a corrupt
        // payload: NaN -> 0, +Inf -> greatestFiniteMagnitude, -Inf ->
        // -greatestFiniteMagnitude (no in-module Foundation needed; pure stdlib).
        private func _patchEncodeResult(_ value: Double) -> Int64 {
            var json = Array("{\\"value\\":".utf8)
            json.append(contentsOf: _patchEncodeFiniteNumber(value))
            json.append(UInt8(ascii: "}"))
            return _patchPackJSON(json)
        }
        """
    }

    /// One scalar-field read from a NAMED byte buffer, into a NAMED local. Used both
    /// for top-level args (`_argsBytes`) and for a reconstructed value type's sub-blob.
    private func t0ScalarReadLines(field: (name: String, type: String), from blob: String,
                                   into local: String, jsonKey: String) -> [String] {
        let t = field.type.trimmingCharacters(in: .whitespaces)
        // `local` may be a backtick-escaped keyword (`` `default` ``); the `_raw_…`
        // temp must NOT embed the backticks (an invalid identifier). Strip them for
        // the temp base (S3).
        let raw = "_raw_\(local.replacingOccurrences(of: "`", with: ""))"
        if T0Marshalling.isString(t) {
            return ["    let \(local) = patchJSONGetString(\(blob), \"\(jsonKey)\")"]
        } else if T0Marshalling.isFloatScalar(t) {
            return ["    let \(raw) = patchJSONGetF64(\(blob), \"\(jsonKey)\")",
                    "    let \(local) = \(t)(\(raw))"]
        } else if T0Marshalling.isBool(t) {
            return ["    let \(raw) = patchJSONGetI64(\(blob), \"\(jsonKey)\")",
                    "    let \(local): Bool = \(raw) != 0"]
        } else {
            return ["    let \(raw) = patchJSONGetI64(\(blob), \"\(jsonKey)\")",
                    "    let \(local) = \(t)(truncatingIfNeeded: \(raw))"]
        }
    }

    /// Reconstruct one value-type boundary field (`fieldName` = `"_receiver"` or a
    /// param name) into a local of the same name: extract its sub-blob with
    /// `json_get_subobject`, read each stored field, and call the memberwise init.
    private func t0ReconstructLines(fieldName: String, shape: PureExport.ValueTypeShape) -> [String] {
        let blob = "_blob_\(fieldName)"
        let lines: [String] = ["    let \(blob) = patchJSONGetSubobject(_argsBytes, \"\(fieldName)\")"]
        return lines + t0ReconstructFromBlob(into: fieldName, blob: blob, shape: shape, prefix: fieldName)
    }

    /// Reconstruct `shape` from an already-extracted sub-`blob` into a local named
    /// `target`. Recursive: a nested value-type field extracts ITS sub-blob from
    /// `blob` and rebuilds in turn (LEVER #1 nested Codable). `prefix` keeps local
    /// names unique across nesting levels (`_receiver_origin_x`).
    private func t0ReconstructFromBlob(into target: String, blob: String,
                                       shape: PureExport.ValueTypeShape, prefix: String) -> [String] {
        var lines: [String] = []
        var initArgs: [String] = []
        for (i, f) in shape.fields.enumerated() {
            let local = "_\(prefix)_\(f.name)"
            if let nested = f.nestedShape {
                // Nested value type: pull its own sub-blob from this blob, then recurse.
                let subBlob = "_blob_\(prefix)_\(f.name)"
                lines.append("    let \(subBlob) = patchJSONGetSubobject(\(blob), \"\(f.name)\")")
                lines += t0ReconstructFromBlob(into: local, blob: subBlob, shape: nested,
                                               prefix: "\(prefix)_\(f.name)")
            } else {
                lines += t0ScalarReadLines(field: (name: f.name, type: f.type),
                                           from: blob, into: local, jsonKey: f.name)
            }
            // The init label: a synthesized memberwise init uses the field name; a
            // positional public init (`init(_ x, …)`) uses no label.
            let label = shape.initLabels.map { $0[i] } ?? f.name
            initArgs.append(label == "_" ? local : "\(label): \(local)")
        }
        lines.append("    let \(target) = \(shape.typeName)(\(initArgs.joined(separator: ", ")))")
        return lines
    }

    /// Synthesize the Embedded `@_cdecl` wrapper for one export: read each scalar
    /// arg from the JSON blob via the host bridge (and reconstruct any value-type
    /// receiver/arg from its nested sub-blob), call the developer's function, and
    /// hand-encode the result. No in-module Foundation/Codable.
    private func t0AbiWrapperSource(
        exportName: String,
        argsFields: [(name: String, type: String)],
        callExpr: String,
        returnType: String,
        valueShapes: [String: PureExport.ValueTypeShape] = [:],
        hasReceiver: Bool = false,
        returnShape: PureExport.ValueTypeShape? = nil
    ) -> String {
        // Sanitize for the @_cdecl string + wrapper func name (Fix A: operators).
        let sym = Self.sanitizedExportSymbol(exportName)
        let fn = "\(sym)__abi"
        var src = ""

        // Decode each arg from the JSON blob by type (research/foundation-bridges):
        //   int/Bool  → patch_host.json_get_i64
        //   String    → patch_host.json_get_string  (packed string)
        //   Double/F. → patch_host.json_get_f64      (the Double's bit-pattern)
        //   value-type → patch_host.json_get_subobject + field-by-field rebuild
        var decodeLines: [String] = []
        let hasValueTypes = !valueShapes.isEmpty
        // The receiver field name is `_receiver`; it is not in `argsFields`.
        if hasReceiver, let shape = valueShapes["_receiver"] {
            decodeLines += t0ReconstructLines(fieldName: "_receiver", shape: shape)
        }
        if argsFields.isEmpty && !hasReceiver && !hasValueTypes {
            decodeLines.append("    _ = _argsBytes  // no arguments to decode")
        } else {
            for f in argsFields {
                if let shape = valueShapes[f.name] {
                    decodeLines += t0ReconstructLines(fieldName: f.name, shape: shape)
                } else {
                    // The decoded scalar local is named after the arg; a keyword-named
                    // arg is backtick-escaped so `let `default` = …` is valid and the
                    // shared call expression (`_args.`default`` → `` `default` `` after
                    // the `_args.` strip below) resolves to it (S3). The JSON key stays
                    // the unescaped name.
                    decodeLines += t0ScalarReadLines(field: f, from: "_argsBytes",
                                                     into: Self.keywordSafeFieldName(f.name), jsonKey: f.name)
                }
            }
        }

        // Call + result-envelope (encoded by return type, no in-module Foundation).
        let trimmedRet = returnType.trimmingCharacters(in: .whitespaces)
        let isVoid = trimmedRet.isEmpty || trimmedRet == "Void"
        let callLines: [String]
        // VALUE-TYPE RETURN (the Codable-return bridge): hand-encode the returned
        // value's stored fields into `{"value":{…}}` via a per-export encoder, no
        // in-guest `Encodable`/JSONEncoder. The native shell decodes the envelope
        // with the app's REAL in-binary `Decodable`. `returnShape` is only non-nil
        // here for a NON-scalar return (the caller pins it so a scalar keeps its
        // existing hand-encoder), so this branch never shadows a scalar path.
        if let rs = returnShape {
            callLines = ["    let _result = \(callExpr)",
                         "    return \(t0ReturnEncoderName(sym))(_result)"]
        } else if isVoid {
            callLines = ["    \(callExpr)", "    return _patchEncodeResult(nil)"]
        } else if T0Marshalling.isBool(trimmedRet) {
            // Explicit Int64 — a bare `1 : 0` literal is now ambiguous between the
            // Int64? and the new UInt64 encode overloads.
            callLines = ["    let _result = \(callExpr)",
                         "    return _patchEncodeResult(_result ? Int64(1) : Int64(0))"]
        } else if T0Marshalling.isString(trimmedRet) {
            callLines = ["    let _result = \(callExpr)",
                         "    return _patchEncodeResult(_result)"]            // String overload
        } else if T0Marshalling.isFloatScalar(trimmedRet) {
            callLines = ["    let _result = \(callExpr)",
                         "    return _patchEncodeResult(Double(_result))"]    // Double overload
        } else if T0Marshalling.isUnsignedScalar(trimmedRet) {
            // UNSIGNED return: `Int64(_result)` TRAPS for a value > Int64.max
            // (UInt/UInt64), crashing the module. Encode the true unsigned
            // magnitude through the UInt64 overload instead.
            callLines = ["    let _result = \(callExpr)",
                         "    return _patchEncodeResult(UInt64(_result))"]    // UInt64 overload
        } else {
            callLines = ["    let _result = \(callExpr)",
                         "    return _patchEncodeResult(Int64(_result))"]
        }

        // The call expression refers to the scalar locals by bare name; the
        // shared `callExpression` emits `_args.<name>`, so rewrite to bare names
        // (the T0 wrapper decodes each arg into a local named `<name>`).
        let callLinesBound = callLines.map { $0.replacingOccurrences(of: "_args.", with: "") }

        // Per-export value-type RETURN encoder (only when returnShape is present).
        if let rs = returnShape {
            src += t0ReturnObjectEncoderSource(sym: sym, shape: rs) + "\n"
        }

        src += """
        @_cdecl("\(sym)")
        public func \(fn)(_ ptr: Int32, _ len: Int32) -> Int64 {
            let _argsBytes = _patchReadArgs(ptr, len)
        \(decodeLines.joined(separator: "\n"))
        \(callLinesBound.joined(separator: "\n"))
        }

        """
        return src
    }

    /// The per-export name of the value-type RETURN object encoder (file-`private`,
    /// one per export so two exports' encoders never collide).
    private func t0ReturnEncoderName(_ sym: String) -> String { "_patchEncodeObj_\(sym)" }

    /// Synthesize the Embedded (T0) hand-encoder for a flat-scalar value-type
    /// RETURN: read each stored field off the returned value and assemble the
    /// canonical `{"value":{"a":…,"b":…}}` envelope with NO in-guest
    /// `Encodable`/JSONEncoder. Per-field encoding (String → escaped+quoted;
    /// Double/Float → finite-clamped decimal; Bool → JSON `true`/`false` — a strict
    /// value-type decode rejects `1`/`0`; Int family → base-10, unsigned via the
    /// true magnitude). Keys are emitted in DECLARATION order; the SDK / native
    /// shell decode by field name, so order is immaterial to fidelity. This is the
    /// encode side of the value-type bridge — the guest never references the app's
    /// `Codable` (which may be `#if !$Embedded`-guarded and vanish under embedded).
    private func t0ReturnObjectEncoderSource(sym: String, shape: PureExport.ValueTypeShape) -> String {
        var body: [String] = []
        body.append("    var _o: [UInt8] = Array(\"{\\\"value\\\":\".utf8)")
        // Encode the returned value's object body, then close the envelope.
        body += t0EncodeObjectBody(accessorRoot: "_value", shape: shape)
        body.append("    _o.append(contentsOf: Array(\"}\".utf8))")
        body.append("    return _patchPackJSON(_o)")
        return """
        // Value-type RETURN encoder (the Codable-return bridge) — hand-encodes the
        // returned value's stored fields (incl. NESTED value-type fields, recursively),
        // with NO in-guest JSON coder or derived conformance (the native shell decodes
        // the envelope with its real Decodable).
        private func \(t0ReturnEncoderName(sym))(_ _value: \(shape.typeName)) -> Int64 {
        \(body.joined(separator: "\n"))
        }
        """
    }

    /// Emit the `{…}` object body for `shape` reading off `accessorRoot` (`_value` or a
    /// nested `_value.origin`). Recursive over nested value-type fields (LEVER #1):
    /// a nested field opens its own `{…}` and encodes its stored fields in turn. The
    /// leading `{` and trailing `}` are emitted here; the caller supplies any key
    /// prefix. Per-field scalar encoding matches the strict value-type fidelity
    /// contract (Bool → JSON `true`/`false`, Double → finite-clamped, String → escaped).
    private func t0EncodeObjectBody(accessorRoot: String, shape: PureExport.ValueTypeShape) -> [String] {
        var body: [String] = ["    _o.append(UInt8(ascii: \"{\"))"]
        for (i, f) in shape.fields.enumerated() {
            let t = f.type.trimmingCharacters(in: .whitespaces)
            let keyPrefix = (i == 0 ? "" : ",") + "\\\"\(f.name)\\\":"
            body.append("    _o.append(contentsOf: Array(\"\(keyPrefix)\".utf8))")
            let accessor = "\(accessorRoot).\(f.name)"
            if let nested = f.nestedShape {
                // Nested value type → recurse (its own `{…}` object).
                body += t0EncodeObjectBody(accessorRoot: accessor, shape: nested)
            } else if T0Marshalling.isString(t) {
                body.append("    _o.append(UInt8(ascii: \"\\\"\"))")
                body.append("    _o.append(contentsOf: _patchJSONEscape(\(accessor)))")
                body.append("    _o.append(UInt8(ascii: \"\\\"\"))")
            } else if T0Marshalling.isBool(t) {
                // A struct field decoded by the app's REAL Codable requires a JSON
                // BOOLEAN (`true`/`false`) — NOT `1`/`0` (which a strict `Bool` decode
                // rejects as a number). This is the fidelity contract for a value-type
                // field (distinct from the lenient scalar `{"value":N}` envelope).
                body.append("    _o.append(contentsOf: Array((\(accessor) ? \"true\" : \"false\").utf8))")
            } else if T0Marshalling.isFloatScalar(t) {
                // Finite-clamp inline (mirrors _patchEncodeResult(Double)): NaN→0,
                // ±Inf→±greatestFiniteMagnitude, else the stdlib decimal form.
                body.append("    _o.append(contentsOf: _patchEncodeFiniteNumber(Double(\(accessor))))")
            } else if T0Marshalling.isUnsignedScalar(t) {
                body.append("    _o.append(contentsOf: Array(String(UInt64(\(accessor))).utf8))")
            } else {
                body.append("    _o.append(contentsOf: Array(String(Int64(\(accessor))).utf8))")
            }
        }
        body.append("    _o.append(UInt8(ascii: \"}\"))")
        return body
    }

    // MARK: - @_cdecl JSON (ptr,len) ABI wrapper synthesis

    /// The guest allocator (the SDK's `patch_malloc`/`patch_free` convention).
    /// Emitted once per wasm file that carries any ABI wrapper.
    private func allocatorSource() -> String {
        """
        // Guest allocator — the host writes argument blobs into these buffers and
        // reads result blobs back out (the SDK's `patch_malloc`/`patch_free` ABI).
        @_cdecl("patch_malloc")
        public func patch_malloc(_ size: Int32) -> Int32 {
            let n = Int(size)
            let p = UnsafeMutableRawPointer.allocate(byteCount: max(n, 1), alignment: 8)
            return Int32(truncatingIfNeeded: Int(bitPattern: p))
        }

        @_cdecl("patch_free")
        public func patch_free(_ ptr: Int32) {
            UnsafeMutableRawPointer(bitPattern: Int(ptr))?.deallocate()
        }
        """
    }

    /// Synthesize the `Args`/`Out` JSON envelopes + the `@_cdecl` wrapper for one
    /// export. `callExpr` calls the underlying function; `argsFields` decode into
    /// it; `outputs` (empty for Void) become one field each on the result envelope
    /// (named tuples are NOT Codable, so multi-output results are flattened into a
    /// struct rather than wrapped in a tuple). The host bridge mirrors this shape.
    private func abiWrapperSource(
        exportName: String,
        argsFields: [(name: String, type: String)],
        callExpr: String,
        outputs: [(name: String, type: String)]
    ) -> String {
        // Sanitize the export symbol so an operator/odd name yields valid Swift for
        // the @_cdecl string, the wrapper func, and the _Args/_Out structs (Fix A).
        let sym = Self.sanitizedExportSymbol(exportName)
        // The wrapper Swift function name (distinct from the @_cdecl export name).
        let fn = "\(sym)__abi"
        let argsType = "\(sym)_Args"
        let outType = "\(sym)_Out"

        // Args envelope: `{ "a": ..., "b": ... }`. An empty-arg export still reads
        // a (possibly empty) buffer and ignores it.
        var src = ""
        if argsFields.isEmpty {
            src += "private struct \(argsType): Decodable {}\n"
        } else {
            src += "private struct \(argsType): Decodable {\n"
            for f in argsFields { src += "    let \(Self.keywordSafeFieldName(f.name)): \(f.type)\n" }
            src += "}\n"
        }

        // Out envelope: one field per output (flattened). Void → empty object.
        if outputs.isEmpty {
            src += "private struct \(outType): Encodable {}\n"
        } else {
            src += "private struct \(outType): Encodable {\n"
            for o in outputs { src += "    let \(Self.keywordSafeFieldName(o.name)): \(o.type)\n" }
            src += "}\n"
        }

        // The call + result-envelope expression.
        let resultExpr: String
        switch outputs.count {
        case 0:
            resultExpr = "\(callExpr)\n    let _out = \(outType)()"
        case 1:
            // Single output (a whole-function value or one live-out): the call
            // returns it directly. A non-finite float result is clamped so the
            // JSONEncoder doesn't throw (which would emit `{}` and crash decode).
            let v0 = Self.isClampableFloatType(outputs[0].type) ? "_patchFinite(_result)" : "_result"
            resultExpr = "let _result = \(callExpr)\n    let _out = \(outType)(\(Self.keywordSafeFieldName(outputs[0].name)): \(v0))"
        default:
            // Multiple live-outs: the fragment returns a named tuple; spread it. Both
            // the struct-init label and the tuple-member read are keyword-escaped (S3).
            let init_ = outputs.map { o -> String in
                let read = "_result.\(Self.keywordSafeFieldName(o.name))"
                let v = Self.isClampableFloatType(o.type) ? "_patchFinite(\(read))" : read
                return "\(Self.keywordSafeFieldName(o.name)): \(v)"
            }.joined(separator: ", ")
            resultExpr = "let _result = \(callExpr)\n    let _out = \(outType)(\(init_))"
        }

        let decodeArgs = argsFields.isEmpty
            ? "    _ = _inData  // no arguments to decode"
            : "    let _args = try! JSONDecoder().decode(\(argsType).self, from: _inData)"

        src += """

        @_cdecl("\(sym)")
        public func \(fn)(_ ptr: Int32, _ len: Int32) -> Int64 {
            let _inData: Data
            if len > 0, let _base = UnsafeRawPointer(bitPattern: Int(ptr)) {
                _inData = Data(bytes: _base, count: Int(len))
            } else {
                _inData = Data()
            }
        \(decodeArgs)
            \(resultExpr)
            let _outData = (try? JSONEncoder().encode(_out)) ?? Data("{}".utf8)
            let _outLen = _outData.count
            let _outRaw = UnsafeMutableRawPointer.allocate(byteCount: max(_outLen, 1), alignment: 8)
            _outData.withUnsafeBytes { _src in
                if let _b = _src.baseAddress, _outLen > 0 { _outRaw.copyMemory(from: _b, byteCount: _outLen) }
            }
            let _outPtr = Int(bitPattern: _outRaw)
            return (Int64(_outPtr) << 32) | Int64(_outLen)
        }

        """
        return src
    }

    // MARK: - Fragment functions (the lifted pure Swift)

    private func makeFragmentFunction(_ fragment: SplitPlan.PureFragment) -> FunctionDeclSyntax {
        var generics: [String] = []
        let params = fragment.inputs.enumerated().map { idx, input -> FunctionParameterSyntax in
            let type: String
            if input.type == "_" {
                let g = "T\(idx)"
                generics.append(g)
                type = g
            } else {
                type = input.type
            }
            return FunctionParameterSyntax(
                firstName: .wildcardToken(),
                secondName: .identifier(input.name),
                colon: .colonToken(),
                type: TypeSyntax(stringLiteral: type)
            )
        }
        let paramList = FunctionParameterListSyntax { for p in params { p } }

        let returnClause: ReturnClauseSyntax?
        switch fragment.outputs.count {
        case 0: returnClause = nil
        case 1:
            let t = fragment.outputs[0].type == "_" ? inferReturnGeneric(&generics) : fragment.outputs[0].type
            returnClause = ReturnClauseSyntax(type: TypeSyntax(stringLiteral: t))
        default:
            let tuple = "(" + fragment.outputs.map { "\($0.name): \(typeOrInferred($0.type, &generics))" }
                .joined(separator: ", ") + ")"
            returnClause = ReturnClauseSyntax(type: TypeSyntax(stringLiteral: tuple))
        }

        let signature = FunctionSignatureSyntax(
            parameterClause: FunctionParameterClauseSyntax(parameters: paramList),
            returnClause: returnClause
        )
        let joined = fragment.bodyStatements.joined(separator: "\n")
        let parsedItems = CodeBlockItemListSyntax("\(raw: joined)")
        let body = CodeBlockSyntax(statements: parsedItems)

        let finalGenericClause: GenericParameterClauseSyntax? = generics.isEmpty ? nil :
            GenericParameterClauseSyntax(parameters: GenericParameterListSyntax {
                for g in generics { GenericParameterSyntax(name: .identifier(g)) }
            })

        return FunctionDeclSyntax(
            name: .identifier(fragment.name),
            genericParameterClause: finalGenericClause,
            signature: signature,
            body: body
        )
    }

    private func typeOrInferred(_ t: String, _ generics: inout [String]) -> String {
        if t == "_" { return inferReturnGeneric(&generics) }
        return t
    }
    private func inferReturnGeneric(_ generics: inout [String]) -> String {
        let g = "R\(generics.count)"
        generics.append(g)
        return g
    }

    // MARK: - Bridge file (rewired native shell)

    private func emitBridgeFile(_ plan: SplitPlan) -> String {
        let rawBase = plan.originalSimpleName.split(separator: "(").first.map(String.init)
            ?? plan.originalSimpleName
        // Fix A/C: sanitize so an operator/empty original name yields a valid native
        // shell type + function name (`==` → `Op_eqeqBridge` / `func op_eqeq(...)`).
        let base = Self.sanitizedFileBase(rawBase)
        let typeName = base.prefix(1).uppercased() + base.dropFirst() + "Bridge"

        // Build the rewired body, step by step.
        var lines: [String] = []
        for step in plan.shellSteps {
            switch step {
            case .nativeStatement(let s):
                lines.append(s)
            case .fragmentCall(let frag):
                lines.append(fragmentCallLine(frag))
            case let .guardConditionCall(frag, rewritten):
                lines.append(fragmentCallLine(frag))
                lines.append(rewritten)
            case let .subExprCall(frag, rewritten):
                lines.append(fragmentCallLine(frag))
                lines.append(rewritten)
            }
        }
        let bodyText = lines.map { "        " + $0 }.joined(separator: "\n")

        let effects = [plan.isAsync ? "async" : nil, plan.isThrows ? "throws" : nil]
            .compactMap { $0 }.joined(separator: " ")
        let arrow = (plan.returnType.isEmpty || plan.returnType == "Void") ? "" : " -> \(plan.returnType)"
        let effectsClause = effects.isEmpty ? "" : " \(effects)"

        let fragmentList = plan.pureFragments.map { "    //   \($0.name)(\($0.inputs.map { $0.name }.joined(separator: ", ")))" }
            .joined(separator: "\n")

        // Per-fragment private JSON envelopes the rewired shell uses to call the
        // WASM export through the SDK. Only ABI-eligible fragments (concrete I/O)
        // get a real call; a generic fragment would never have been exported.
        var envelopes = ""
        for frag in plan.pureFragments where abiEligible(frag) {
            envelopes += bridgeEnvelopes(for: frag) + "\n"
        }

        let source = """
        // Auto-generated by Patch — native shell for \(plan.originalID).
        // Stays in the App Store binary. DO NOT EDIT.
        //
        // The body below is the original function rewired: each lifted pure run
        // is dispatched to WASM via Patch.call(...), native statements are kept
        // verbatim, and values are threaded through the call boundary. Patch.call
        // marshals args → invokes the @_cdecl export via the SDK → decodes the
        // JSON result (the ABI in <frag>_wasm.swift).
        //
        // Pure fragments dispatched to WASM:
        \(fragmentList.isEmpty ? "    //   (none)" : fragmentList)

        import Foundation
        import PatchSDK

        \(envelopes)enum \(typeName) {
            static func \(plan.nativeSignature.isEmpty ? "\(base)()" : signatureForShell(plan, base: base))\(effectsClause)\(arrow) {
        \(bodyText)
            }
        }

        /// Patch runtime shim — dispatches a call into the active WASM module via
        /// the SDK, using JSON as the structured codec (matching the guest's
        /// generated `@_cdecl` ABI). Force-unwraps because a rewired native run
        /// has no native fallback path; a runtime failure is a build/ABI bug, not
        /// a recoverable condition.
        enum Patch {
            static func call<A: Encodable, R: Decodable>(_ name: String, _ args: A, returning: R.Type) -> R {
                return try! PatchSDK.Patch.shared.callJSON(name, args, returning: R.self)
            }
        }
        """
        return source
    }

    /// The private `Args`/`Out` JSON envelopes the bridge uses for one fragment.
    /// Mirrors the guest's flattened envelope shape exactly.
    private func bridgeEnvelopes(for frag: SplitPlan.PureFragment) -> String {
        // Mirror the guest's sanitized symbol so the native envelopes match the WASM
        // `@_cdecl`/struct names (Fix A; a no-op for valid `_sp_…` fragment names).
        let sym = Self.sanitizedExportSymbol(frag.name)
        let argsType = "\(sym)_Args"
        let outType = "\(sym)_Out"
        var s = ""
        if frag.inputs.isEmpty {
            s += "private struct \(argsType): Encodable {}\n"
        } else {
            s += "private struct \(argsType): Encodable {\n"
            for f in frag.inputs { s += "    let \(Self.keywordSafeFieldName(f.name)): \(f.type)\n" }
            s += "}\n"
        }
        if frag.outputs.isEmpty {
            s += "private struct \(outType): Decodable {}\n"
        } else {
            s += "private struct \(outType): Decodable {\n"
            for o in frag.outputs { s += "    let \(Self.keywordSafeFieldName(o.name)): \(o.type)\n" }
            s += "}\n"
        }
        return s
    }

    /// Reconstruct the shell function signature from the original parameters. A
    /// keyword-named param binding (`default`, `where`, …) is backtick-escaped (S3);
    /// SwiftSyntax `.text` strips the dev's original backticks, so we re-add them.
    private func signatureForShell(_ plan: SplitPlan, base: String) -> String {
        let params = plan.originalParameters
            .map { "_ \(Self.keywordSafeFieldName($0.name)): \($0.type)" }
            .joined(separator: ", ")
        return "\(base)(\(params))"
    }

    /// Emit the `let (outs) = ...Patch.call("frag", ...)` line for a fragment. For
    /// an ABI-eligible fragment this is a real SDK call decoding the JSON result;
    /// a non-ABI (generic) fragment can't cross the boundary, so it is kept as a
    /// documented unavailable call (such fragments are never actually exported and
    /// the splitter keeps them native).
    private func fragmentCallLine(_ frag: SplitPlan.PureFragment) -> String {
        guard abiEligible(frag) else {
            // Should not occur in a shipped module (non-ABI fragments are not
            // exported); emit a clear runtime trap so a mis-wired build is caught.
            return "fatalError(\"fragment \\\"\(frag.name)\\\" has a non-ABI signature and was not exported\")"
        }
        let sym = Self.sanitizedExportSymbol(frag.name)
        let argsType = "\(sym)_Args"
        let outType = "\(sym)_Out"
        // The struct-init label and the native local holding the value are BOTH
        // keyword-escaped (S3) so a keyword-named param/output stays valid Swift in the
        // native shell (the dev's keyword-named param is declared backtick-escaped in
        // `signatureForShell`, so the value reference must match).
        let argsInit = frag.inputs.isEmpty
            ? "\(argsType)()"
            : "\(argsType)(" + frag.inputs.map {
                "\(Self.keywordSafeFieldName($0.name)): \(Self.keywordSafeFieldName($0.name))"
              }.joined(separator: ", ") + ")"
        // The Patch.call symbol MUST equal the WASM `@_cdecl` export (the sanitized
        // name) so the native shell invokes the right export.
        let callExpr = "Patch.call(\"\(sym)\", \(argsInit), returning: \(outType).self)"
        switch frag.outputs.count {
        case 0:
            return "_ = \(callExpr)"
        case 1:
            let o = Self.keywordSafeFieldName(frag.outputs[0].name)
            return "let \(o) = \(callExpr).\(o)"
        default:
            let tmp = "\(sym)_r"
            var s = "let \(tmp) = \(callExpr)\n"
            s += frag.outputs.map {
                let o = Self.keywordSafeFieldName($0.name)
                return "        let \(o) = \(tmp).\(o)"
            }.joined(separator: "\n")
            return s
        }
    }

    // expose for BuildPipeline
    public func isABIEligible(_ fragment: SplitPlan.PureFragment) -> Bool { abiEligible(fragment) }
}
