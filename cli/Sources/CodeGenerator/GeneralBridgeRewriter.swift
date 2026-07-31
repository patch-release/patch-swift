// SPDX-License-Identifier: Apache-2.0

import Foundation

// ===========================================================================
// LEVER #2 (part B) — the GENERALIZED "call what's already linked" rewriter.
//
// The curated `FusionRewriter` (this file's sibling) routes a CLOSED, hand-
// authored set of ~51 native leaves to per-leaf `patch_host.<name>` imports.
// Each leaf costs four hand-written surfaces (a C decl, a flat WASM import, an
// SDK `imports.host` registration, a classifier entry). Any call to an
// UN-curated native symbol — the app's own types, an arbitrary Foundation API,
// a third-party SPM dependency — still forces the whole enclosing function
// native.
//
// `GeneralBridgeRewriter` generalizes the curated mechanism to ARBITRARY
// already-linked symbols through ONE generic dispatch import
// (`patch_host.call(symbolId, argBlob) -> resultBlob`). The classifier decides
// which call sites are PROVABLY safe to route (DESIGN §4.1 / §6) and the
// rewriter emits the guest-side marshalling sequence around each routed call,
// wrapped in a demote-safe native fallback.
//
// This file owns the CLASSIFIER + the guest-sequence emission. The TLV ABI
// core (symbol-id derivation, the arg-blob/result-decoder codegen, the manifest
// model) is owned by a PARALLEL agent; this file codes against the small
// `HostBridgeABIProvider` interface below (with a self-contained `StubHostBridgeABI`
// so the component compiles + tests standalone). At integration the stub is
// swapped for the real ABI core — see the interface docs in
// `HostBridgeABIInterface.swift`.
//
// DEMOTE-ON-DOUBT is mandatory: if the classifier cannot PROVE a call site is
// safely routable, the call is left VERBATIM (stays native). The convergence
// loop + the emitted `have()`/`.error` fallback are the runtime safety net.
// ===========================================================================
public struct GeneralBridgeRewriter {

    /// The ABI-core seam. Injected so the real ABI core (parallel agent) is a
    /// drop-in for the stub. See `HostBridgeABIInterface.swift`.
    public let abi: HostBridgeABIProvider

    public init(abi: HostBridgeABIProvider = StubHostBridgeABI()) {
        self.abi = abi
    }

    // =======================================================================
    // MARK: - Routable-call classification (DESIGN §4.1 / §6)
    // =======================================================================

    /// One classified call site the engine is considering routing through the
    /// generic bridge. The classifier produces this from a parsed call form; the
    /// rewriter emits the guest sequence from it.
    public struct CallSite: Sendable, Equatable {
        public enum Form: Sendable, Equatable {
            /// A free function or a static method on a non-reconstructable type,
            /// e.g. `PricingEngine.discount(_:_:)`. `receiver` is the qualifier
            /// (`"PricingEngine"`) or empty for a bare free function.
            case freeOrStatic(receiver: String, function: String)
            /// A curated Foundation stateless leaf (the survey's quartet:
            /// `NotificationCenter.post` / `FileManager` basics / `openURL`).
            /// Recognized by an exact canonical receiver path.
            case foundationStateless(canonicalReceiver: String, function: String)
        }
        public let form: Form
        /// The marshallable argument values, in declaration order. Each is a
        /// value the guest already holds (a scalar/string/bool the body produces,
        /// or a handle from a prior routed call).
        public let args: [BridgeArg]
        /// The return type's marshalling tag (or `.nilValue` for `Void`).
        public let returnTag: HostBridgeValueTag
        /// The verbatim native source span this call site occupies (for the
        /// fallback path the wrapper keeps).
        public let nativeExpr: String
        /// The fully-qualified canonical signature the ABI core hashes to a
        /// stable symbol id (`"MyApp.PricingEngine.discount(subtotal:Double,tier:Int)->Double"`).
        public let canonicalSignature: String

        public init(form: Form, args: [BridgeArg], returnTag: HostBridgeValueTag,
                    nativeExpr: String, canonicalSignature: String) {
            self.form = form
            self.args = args
            self.returnTag = returnTag
            self.nativeExpr = nativeExpr
            self.canonicalSignature = canonicalSignature
        }
    }

    /// A single argument to a routed call: the guest-side expression that
    /// produces the value + the wire tag it marshals as.
    public struct BridgeArg: Sendable, Equatable {
        public let expr: String
        public let tag: HostBridgeValueTag
        public init(expr: String, tag: HostBridgeValueTag) {
            self.expr = expr
            self.tag = tag
        }
    }

    /// The reasons a call site is kept native (never routed). Surfaced for the
    /// "why didn't this lower" diagnostic + the demote-safety tests.
    public enum DemoteReason: String, Sendable, Equatable {
        case inoutArgument          // §8.3 — no in/out blob protocol
        case escapingClosureArg     // §8.2 — host→guest callback is out of scope
        case unspecializedGeneric   // §8.4 — no single native symbol to resolve
        case unsafePointer          // §8.5 — guest-linear-memory address is meaningless natively
        case metatypeArg            // §8 — engine can't concretize a metatype
        case unmarshallableArgType  // a by-reference value the guest would synthesize (not a handle)
        case unmarshallableReturn   // a by-reference return that isn't a registered handle type
        case crossThreadOrActor     // §6 — native object must be touched off the guest thread
        case variadic               // §6 — variadic call has no fixed arg list
        case unresolvableSymbol     // §4.1 — not a generated-thunk-resolvable symbol
        case unrecognizedShape      // not a form the classifier understands → conservative demote
    }

    /// Classification verdict for a call site.
    public enum Verdict: Sendable, Equatable {
        case route(CallSite)
        case demote(DemoteReason)
    }

    // -----------------------------------------------------------------------
    // The hard demote-gates (DESIGN §6). These fire on the RAW call text before
    // any structural parse — a conservative pre-filter. If ANY fires, demote.
    // -----------------------------------------------------------------------

    /// Tokens whose presence in a call's argument list make it un-routable. Each
    /// maps to the DESIGN §8 hard limit it represents. Matched as a code token
    /// (word-boundary / sigil), not inside a string literal.
    static let hardDemoteTokens: [(token: String, reason: DemoteReason)] = [
        ("inout ", .inoutArgument),
        ("UnsafePointer", .unsafePointer),
        ("UnsafeMutablePointer", .unsafePointer),
        ("UnsafeRawPointer", .unsafePointer),
        ("UnsafeMutableRawPointer", .unsafePointer),
        ("UnsafeBufferPointer", .unsafePointer),
        ("withUnsafe", .unsafePointer),
        (".self", .metatypeArg),          // a metatype literal passed as an arg
        ("#selector", .unresolvableSymbol),
    ]

    /// Decide whether a parsed call site is routable. PURE structural check —
    /// every gate is a PROOF the call is safe; absence of proof is a demote.
    ///
    /// The caller (the engine's call-site extractor, parallel work) supplies the
    /// structured `Candidate`; this method is the demote-on-doubt gate.
    public func classify(_ candidate: Candidate) -> Verdict {
        // 1. Hard-token pre-filter over the raw native expression + arg exprs.
        let haystack = ([candidate.nativeExpr] + candidate.argExprs).joined(separator: "\u{1}")
        for (tok, reason) in Self.hardDemoteTokens where Self.containsCodeToken(haystack, tok) {
            return .demote(reason)
        }
        // 2. Explicit structural flags the extractor may have already determined.
        if candidate.hasInoutArg { return .demote(.inoutArgument) }
        if candidate.hasEscapingClosureArg { return .demote(.escapingClosureArg) }
        if candidate.isUnspecializedGeneric { return .demote(.unspecializedGeneric) }
        if candidate.isVariadic { return .demote(.variadic) }
        if candidate.touchesCrossThreadObject { return .demote(.crossThreadOrActor) }

        // 3. Every arg must be by-value-marshallable OR an already-produced handle.
        var args: [BridgeArg] = []
        for a in candidate.args {
            guard let tag = Self.marshallableTag(a.swiftType, isHandle: a.isHandle) else {
                return .demote(.unmarshallableArgType)
            }
            args.append(BridgeArg(expr: a.expr, tag: tag))
        }

        // 4. The return must be by-value-marshallable OR a registered handle type.
        guard let retTag = Self.marshallableReturnTag(candidate.returnType,
                                                       isHandle: candidate.returnIsHandle) else {
            return .demote(.unmarshallableReturn)
        }

        // 5. The symbol must be resolvable as a generated thunk (the host's job;
        // the extractor sets this once it has consulted the routed-symbol set).
        guard candidate.symbolResolvable else { return .demote(.unresolvableSymbol) }

        let form: CallSite.Form
        switch candidate.kind {
        case .freeOrStatic:
            form = .freeOrStatic(receiver: candidate.receiver, function: candidate.function)
        case .foundationStateless:
            form = .foundationStateless(canonicalReceiver: candidate.receiver,
                                        function: candidate.function)
        }
        let site = CallSite(form: form, args: args, returnTag: retTag,
                            nativeExpr: candidate.nativeExpr,
                            canonicalSignature: candidate.canonicalSignature)
        return .route(site)
    }

    /// A by-value or handle arg type → its wire tag, else nil (demote).
    /// Mirrors DESIGN §3.1. Flat-scalar Codable rides as `bytes` (the existing
    /// value-type envelope); any reference/unknown type is a demote unless it's
    /// already a handle.
    static func marshallableTag(_ swiftType: String, isHandle: Bool) -> HostBridgeValueTag? {
        if isHandle { return .handle }
        let t = swiftType.trimmingCharacters(in: .whitespaces)
        switch t {
        case "Int", "Int64", "Int32", "Int16", "Int8",
             "UInt", "UInt64", "UInt32", "UInt16", "UInt8":
            return .i64
        case "Double", "Float", "CGFloat":
            return .f64
        case "Bool":
            return .bool
        case "String":
            return .string
        case "Data", "[UInt8]":
            return .bytes
        default:
            // A flat-scalar Codable struct/array rides as a `bytes` JSON sub-blob
            // ONLY if the extractor proved it Codable+flat (it sets `isHandle=false`
            // and a type we don't recognize here). We DEMOTE on an unknown type:
            // proving Codable-flatness is the extractor's job, and absent that
            // proof a reference type would be silently mis-marshalled. Conservative.
            return nil
        }
    }

    /// The return tag. `Void`/`()` → `.nilValue`; otherwise same rules as an arg,
    /// plus a handle for a registered reference return.
    static func marshallableReturnTag(_ swiftType: String, isHandle: Bool) -> HostBridgeValueTag? {
        let t = swiftType.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t == "Void" || t == "()" { return .nilValue }
        return marshallableTag(t, isHandle: isHandle)
    }

    // =======================================================================
    // MARK: - Guest-sequence emission (DESIGN §6)
    //
    // A routed call becomes the demote-safe sequence:
    //
    //   { () -> <RetType> in
    //       if patch_host.have(<id>) == 0 { return <native fallback> }
    //       var __pb = <ABI ArgWriter>()
    //       __pb.<tag>(<argExpr>)   // one per arg
    //       let __pr = patch_host.call(<id>, __pb)
    //       switch __pr {
    //       case .<retTag>(let v): return v
    //       default: return <native fallback>   // .error tag → demote
    //       }
    //   }()
    //
    // The arg-blob builder + result decoder are codegen the ABI core owns; this
    // method composes them around the classified site. The fallback expression
    // is the VERBATIM native call, so an unresolved/errored route runs the real
    // native code — never wrong results.
    // =======================================================================

    /// The emitted guest sequence for a routed call site. The ABI core supplies
    /// the symbol-id literal, the arg-blob builder snippet, and the result-decode
    /// snippet; this composes them with the `have()` pre-flight + `.error`
    /// fallback into a self-contained closure expression.
    public func emitGuestSequence(_ site: CallSite) -> String {
        let id = abi.symbolIdLiteral(forCanonicalSignature: site.canonicalSignature)
        let retType = abi.swiftReturnType(for: site.returnTag, isHandle: site.returnTag == .handle)

        // Build the arg blob via the ABI core's writer codegen.
        let argEncodes = site.args.map { abi.argEncodeStatement(writerVar: "__pb", tag: $0.tag, expr: $0.expr) }
        let argBlock = argEncodes.isEmpty ? "" : argEncodes.joined(separator: "\n        ") + "\n        "

        // Decode the single result record for the declared return tag.
        let decodeSuccess = abi.resultDecodeSuccessPattern(for: site.returnTag)   // e.g. ".f64(let __v)"
        let successBind = abi.resultSuccessExpression(for: site.returnTag)        // e.g. "__v" / "()"

        return """
        { () -> \(retType) in
            if \(abi.haveImportCall(symbolIdLiteral: id)) == 0 { return \(site.nativeExpr) }
            var __pb = \(abi.makeArgWriterExpression())
            \(argBlock)let __pr = \(abi.callImportExpression(symbolIdLiteral: id, writerVar: "__pb"))
            switch __pr {
            case \(decodeSuccess): return \(successBind)
            default: return \(site.nativeExpr)
            }
        }()
        """
    }

    // =======================================================================
    // MARK: - The classifier's structured input
    //
    // The engine's call-site extractor (parallel work, not this file) produces a
    // `Candidate` from a parsed call form. Defined here so this component
    // classifies + emits standalone and is testable without the extractor.
    // =======================================================================

    /// A candidate call site, as the extractor would hand it to the classifier.
    public struct Candidate: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case freeOrStatic
            case foundationStateless
        }
        public let kind: Kind
        /// The qualifier (`"PricingEngine"`, `"NotificationCenter.default"`) or
        /// empty for a bare free function.
        public let receiver: String
        /// The called function/member name (`"discount"`, `"post"`).
        public let function: String
        /// The verbatim native call expression (the fallback path).
        public let nativeExpr: String
        /// The fully-qualified canonical signature for the ABI core's id hash.
        public let canonicalSignature: String
        /// The structured argument list.
        public let args: [Arg]
        /// The declared return type (`"Double"`, `"Void"`, `""`).
        public let returnType: String
        /// True iff the return is a registered host handle type (a reference the
        /// host proxies, not a value the guest reconstructs).
        public let returnIsHandle: Bool
        // Structural demote flags the extractor may have determined directly.
        public let hasInoutArg: Bool
        public let hasEscapingClosureArg: Bool
        public let isUnspecializedGeneric: Bool
        public let isVariadic: Bool
        public let touchesCrossThreadObject: Bool
        /// True iff the symbol is in the routed-symbol set (a generated thunk
        /// resolves it in the target build). The extractor consults that set.
        public let symbolResolvable: Bool

        /// Convenience for the raw-token pre-filter: every arg's expression.
        public var argExprs: [String] { args.map(\.expr) }

        public struct Arg: Sendable, Equatable {
            public let expr: String
            public let swiftType: String
            /// True iff this arg is a handle from a PRIOR routed call.
            public let isHandle: Bool
            public init(expr: String, swiftType: String, isHandle: Bool = false) {
                self.expr = expr
                self.swiftType = swiftType
                self.isHandle = isHandle
            }
        }

        public init(kind: Kind, receiver: String, function: String,
                    nativeExpr: String, canonicalSignature: String,
                    args: [Arg], returnType: String, returnIsHandle: Bool = false,
                    hasInoutArg: Bool = false, hasEscapingClosureArg: Bool = false,
                    isUnspecializedGeneric: Bool = false, isVariadic: Bool = false,
                    touchesCrossThreadObject: Bool = false, symbolResolvable: Bool = true) {
            self.kind = kind
            self.receiver = receiver
            self.function = function
            self.nativeExpr = nativeExpr
            self.canonicalSignature = canonicalSignature
            self.args = args
            self.returnType = returnType
            self.returnIsHandle = returnIsHandle
            self.hasInoutArg = hasInoutArg
            self.hasEscapingClosureArg = hasEscapingClosureArg
            self.isUnspecializedGeneric = isUnspecializedGeneric
            self.isVariadic = isVariadic
            self.touchesCrossThreadObject = touchesCrossThreadObject
            self.symbolResolvable = symbolResolvable
        }
    }

    // =======================================================================
    // MARK: - Code-token matching (don't fire inside a string literal / comment)
    //
    // Reuses the FusionRewriter's discipline: a token that appears inside a
    // `"…"` literal must NOT be treated as code. For the pre-filter we mask the
    // string with the shared codeMask + require the matched token's head be in
    // a code region. We OR the args together with a non-code sentinel (\u{1})
    // so a literal in one arg can't bleed into the next.
    // =======================================================================
    static func containsCodeToken(_ haystack: String, _ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        let mask = FusionRewriter.codeMask(haystack)
        let hay = Array(haystack.utf16)
        let tok = Array(token.utf16)
        guard tok.count <= hay.count else { return false }
        var i = 0
        while i + tok.count <= hay.count {
            if hay[i] == tok[0] {
                var match = true
                for j in 0..<tok.count where hay[i + j] != tok[j] { match = false; break }
                // The token's HEAD must be in a code region (not a masked literal).
                if match, i < mask.count, mask[i] { return true }
            }
            i += 1
        }
        return false
    }
}
