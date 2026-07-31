// SPDX-License-Identifier: Apache-2.0

// HostBridgeThunkGenerator.swift — build-time codegen for the GENERALIZED
// "call what's already linked" host bridge (PRODUCTION Lever #2, part B / DESIGN §4.2).
// =============================================================================
// This is the App-Store-clean RESOLUTION mechanism for the generalized host bridge.
//
// Background (DESIGN.md §0–§4). Today an un-bridged native call (the app's own
// types, an arbitrary Foundation API, a third-party SDK) forces the whole enclosing
// function native. The generalized bridge replaces the per-leaf import set with ONE
// generic dispatch import: the guest calls `patch_host.call(symbolId, argsBlob)`, and
// the host resolves `symbolId` to a real native thunk. The hard question is HOW the
// host resolves `symbolId` to a real native call WITHOUT `dlsym` / ObjC-runtime
// spelunking (App-Store-risky). DESIGN §4.2's preferred answer — implemented here:
//
//   BUILD-TIME GENERATED THUNKS. Exactly like the SwiftUI `@_dynamicReplacement`
//   thunks + `__patchSlots()`/`__patchTokens()` (`ThunkGenerator.swift`), `patchcli
//   prepare` generates, *INTO THE APP TARGET*, a small registry of closures — one per
//   symbol the engine intends to route — that call the real native symbol DIRECTLY
//   (`{ args in PricingEngine.discount(subtotal: args.f64(0), tier: Int(args.i64(1))) }`).
//   These compile against the app's real types/SDKs (no reflection, no private-API),
//   so `MyApp.PricingEngine`, a third-party SDK type, and any Foundation API are all
//   reachable. It is NOT "calling an arbitrary symbol by string at runtime" — it's a
//   compiled-in, STATICALLY TYPE-CHECKED dispatch table keyed by the engine's symbol
//   ids. App-Store-legal (only DATA changes at runtime, never code) and ABI-robust.
//
// The output is a single generated Swift file, `PatchHostBridges.generated.swift`,
// placed into the dedicated gitignored `Patch/Generated/` folder (alongside the
// SwiftUI thunks) and compiled into the app. At process start it registers every
// routed symbol's closure with the SDK's host-bridge registry (the SDK then serves
// `patch_host.call(symbolId, …)` by looking the closure up + marshalling TLV).
//
// THE COMPILES-OR-DEMOTE NET (the load-bearing safety property — DESIGN §4.2 / §6).
// If a generated thunk closure does NOT compile against the app's real types (the
// symbol was renamed/removed/made private since the engine routed it), that symbol
// MUST be DROPPED from the routed set (DEMOTE) rather than break the app build. We
// mirror the existing SwiftUI per-view isolation + the `BridgeTypecheck` precedent:
//   1. each symbol is emitted in its OWN isolated region so the build can exclude it;
//   2. `HostBridgeThunkGenerator.validate(...)` host-`swiftc -typecheck`s each symbol's
//      generated thunk against a stub of the app types and DROPS the non-compiling ones
//      BEFORE the final file is emitted — so a non-compiling entry can never reach the
//      developer's Xcode build.
//
// INTEGRATION DEPENDENCIES (defined-and-stubbed here; see the `HostBridgeABI` /
// `HostBridgeRegistryAPI` doc sections at the bottom). The ABI-core agent owns the real
// `TLVTag`/`HostBridgeSymbol`/symbol-id; the SDK-host agent owns the real registration
// API. We define the precise shapes THIS generator emits against so it compiles + tests
// standalone, and document them so the reconnection is mechanical.

import Foundation
import SwiftParser
import SwiftSyntax

// =============================================================================
// MARK: - Routed-symbol description (engine → generator input)
// =============================================================================

/// One native symbol the engine chose to route through the generalized bridge.
///
/// The engine's classifier (DESIGN §4.1) produces these from the routable call sites
/// it found; this generator turns each into a compiled-in dispatch-table entry. This
/// is the generator's INPUT contract — a small, self-describing record so the
/// generator never needs to re-parse the developer's source.
public struct RoutedSymbol: Sendable, Equatable {
    /// The content-addressed stable id (DESIGN §2.3: `truncate32(SHA256(canonicalSignature))`).
    /// The guest carries this as `symbolId`; the SDK registry is keyed by it. We treat it
    /// opaquely here (the ABI-core agent owns the hashing) — the generator only needs it
    /// to key the registration and the per-symbol region marker.
    public let id: Int32

    /// The fully-qualified, demangled canonical signature (DESIGN §2.3), e.g.
    /// `"MyApp.PricingEngine.discount(subtotal:Double,tier:Int)->Double"`. Carried into
    /// the generated registration purely as a human-readable comment + the manifest key —
    /// resolution is by `id`, not by re-parsing this string at runtime.
    public let canonicalSignature: String

    /// The REAL Swift call EXPRESSION to invoke the native symbol, written as a TEMPLATE
    /// with each argument slot a `\u{1}k\u{1}` placeholder (the kth decoded arg) — the same
    /// sentinel-placeholder convention `ThunkGenerator.renderParameterizedTemplate` uses.
    /// E.g. for `PricingEngine.discount(subtotal:tier:)` the engine supplies:
    ///   `"PricingEngine.discount(subtotal: \u{1}0\u{1}, tier: \u{1}1\u{1})"`
    /// The generator substitutes each `\u{1}k\u{1}` with a typed decode of arg k
    /// (`__a.f64(0)` / `Int(__a.i64(1))` / …) per `argTypes`, so the emitted closure is a
    /// direct, statically-type-checked native call. A free function, a static method, and a
    /// handle-receiver method (the receiver is arg 0, a `handle`) all express as one template.
    public let callTemplate: String

    /// The Swift type of each argument, in order — used to pick the right TLV decode for
    /// each `\u{1}k\u{1}` slot. Only the by-value-marshallable + handle types (DESIGN §3) are
    /// routable; anything else means the engine should not have produced this `RoutedSymbol`.
    public let argTypes: [ArgType]

    /// The Swift type of the return — used to pick the right TLV encode of the result.
    public let returnType: ReturnType

    /// The set of plain top-level `import` lines the call template needs in scope (the
    /// module that declares the native symbol + its arg/return types). The generated file
    /// emits each `#if canImport(...)`-guarded, exactly like the SwiftUI thunk file.
    public let requiredImports: [String]

    /// THROWING native symbol (DESIGN §8.7 — the cheap, high-value half). When true, the
    /// native call expression is `try …` and the generated thunk wraps the call in
    /// `do { … } catch { return .error("\(error)") }` — the `.error` TLV tag is ALREADY the
    /// demote channel, so a routed `throws` symbol that throws at runtime falls back to the
    /// guest's native path (a thrown error is never a misdispatch). The CLASSIFIER/EXTRACTOR
    /// must set this whenever the routed call site invokes a `throws` symbol.
    public let isThrowing: Bool

    /// ASYNC native symbol (DESIGN §8.7 — the additive half). When true, the generated
    /// registration uses the controller's `registerAsync(id:signature:)` API and the closure
    /// is `async` (the native call is `await …`, and `await try …` if ALSO `isThrowing`). The
    /// guest routes an async symbol through the `patch_host.call_async` SUSPEND import (vs the
    /// synchronous `patch_host.call`), resumed by the host from the pump stall. The
    /// CLASSIFIER/EXTRACTOR must set this whenever the routed call site invokes an `async`
    /// symbol. NOTE: a `throws`-only symbol is NOT async; an `async throws` symbol sets BOTH.
    public let isAsync: Bool

    public init(id: Int32, canonicalSignature: String, callTemplate: String,
                argTypes: [ArgType], returnType: ReturnType, requiredImports: [String] = [],
                isThrowing: Bool = false, isAsync: Bool = false) {
        self.id = id
        self.canonicalSignature = canonicalSignature
        self.callTemplate = callTemplate
        self.argTypes = argTypes
        self.returnType = returnType
        self.requiredImports = requiredImports
        self.isThrowing = isThrowing
        self.isAsync = isAsync
    }
}

/// The marshallable argument types (DESIGN §3.1–§3.2). Each maps to ONE TLV decode in the
/// generated closure. Deliberately a closed set — the engine's classifier only routes a
/// call all of whose args are one of these; anything else demotes at classification time.
public enum ArgType: Sendable, Equatable {
    case int        // Int / Int64 / Int32 / UInt* (in range)  → TLV i64
    case double     // Double / Float / CGFloat                → TLV f64 (finite-clamped)
    case bool       // Bool                                    → TLV bool
    case string     // String                                  → TLV string (utf8)
    case data       // Data / [UInt8]                          → TLV bytes
    /// A by-reference native object the guest holds as an opaque handle (DESIGN §3.2). The
    /// associated Swift type is what the host casts the resolved handle to (`NumberFormatter`),
    /// so a stale/mismatched handle fails the cast → tagged `.error` → demote.
    case handle(String)
}

/// The marshallable return types (DESIGN §3.1–§3.2). Each maps to ONE TLV encode.
public enum ReturnType: Sendable, Equatable {
    case void       // -> Void / nil          → empty result blob
    case int
    case double
    case bool
    case string
    case data
    /// A constructor / accessor that RETURNS a by-reference native object — retained in the
    /// host handle table, returned to the guest as a TLV `handle` (DESIGN §3.2). The
    /// associated Swift type is the object's declared type (informational; the host retains
    /// it as `AnyObject`).
    case handle(String)
}

// =============================================================================
// MARK: - The generator
// =============================================================================

public struct HostBridgeThunkGenerator {

    /// Which registration ABI the generated thunks target.
    ///
    /// RECONCILIATION (Lever #2 integration): the component was authored against a
    /// SHIM (`PatchBridgeArgs`/`PatchBridgeValue`/`enum PatchHostBridge.register`)
    /// so it compiled + tested standalone. The REAL SDK host runtime
    /// (`sdk/Sources/PatchHostBridge`) exposes a DIFFERENT shape — the integration
    /// contract is:
    ///   * `final class PatchHostBridge` with an INSTANCE method
    ///     `register(id: Int32, signature: String) { (args: ArgReader,
    ///      handles: HandleTable) throws -> TLVValue in … }` (TWO closure params),
    ///   * `ArgReader` accessors `f64/i64/bool/string/bytes/handle` (note `string`,
    ///     NOT `str`),
    ///   * a handle arg resolves via `handles.resolve(_:as:)` (an OPTIONAL — guarded,
    ///     a stale/mismatched handle → throw → tagged `.error`), and a returned
    ///     reference type is retained via `handles.retain(_:)` (on the HandleTable,
    ///     NOT the args),
    ///   * the result enum is `TLVValue` (cases identical to the shim's
    ///     `PatchBridgeValue`).
    ///
    /// `.stubShim` keeps the original standalone shape (the existing unit tests pin
    /// it). `.realSDK` emits the production file that drops into the real SDK — this
    /// is what the vertical-slice end-to-end test compiles + registers + runs.
    public enum RegistrationTarget: Sendable, Equatable {
        case stubShim
        case realSDK
    }

    public let target: RegistrationTarget

    public init(target: RegistrationTarget = .stubShim) {
        self.target = target
    }

    /// The generated file name (lives in the gitignored `Patch/Generated/` folder).
    public static let fileName = "PatchHostBridges.generated.swift"

    /// Per-symbol region markers. Each routed symbol's registration lives in its OWN
    /// `// PATCH-HOSTBRIDGE BEGIN <id>` … `// PATCH-HOSTBRIDGE END <id>` region so the
    /// compiles-or-demote net can isolate and exclude exactly one symbol (mirroring the
    /// SwiftUI per-view isolation in `ThunkGenerator.viewThunkValidates`).
    public static func beginRegion(_ id: Int32) -> String { "// PATCH-HOSTBRIDGE BEGIN \(id)" }
    public static func endRegion(_ id: Int32) -> String { "// PATCH-HOSTBRIDGE END \(id)" }

    /// The function the SDK calls once (at process start) to populate the host-bridge
    /// registry. The generated file declares it; the SDK calls it from its bridge bootstrap.
    public static let registerFunctionName = "__patchRegisterHostBridges"

    public struct Result {
        /// The generated `PatchHostBridges.generated.swift` contents. Empty when no symbol
        /// routed (or all demoted) — the SDK then serves only the curated bridges.
        public var fileContents: String
        /// The ids actually emitted (post-demote), sorted. The engine folds this into the
        /// `patch_host_symbols` manifest + (follow-up) the fingerprint.
        public var emittedSymbolIDs: [Int32]
        /// Symbols DROPPED by the compiles-or-demote net, with the reason — the engine logs
        /// these as a build warning (the routed call stays native).
        public var demoted: [(id: Int32, signature: String, reason: String)]
    }

    // MARK: - Public API

    /// Generate the host-bridge registration file for `symbols`.
    ///
    /// When `validate` is supplied (a `BridgeThunkValidator` — the compiles-or-demote net),
    /// each symbol's generated thunk is host-type-checked against `appTypeStub` (a stub of
    /// the app's real types) and a NON-compiling symbol is DROPPED before the file is
    /// rendered. When `validate` is nil the file is rendered for ALL symbols (the syntax-only
    /// path — the per-symbol region markers still isolate a bad entry should a later
    /// `swiftc` net run). The two-phase shape mirrors `ThunkGenerator.prepare`'s
    /// `viewThunkValidates` filter feeding `renderThunkFile`.
    public func generate(symbols: [RoutedSymbol],
                         validate: BridgeThunkValidator? = nil,
                         appTypeStub: String = "") -> Result {
        var demoted: [(id: Int32, signature: String, reason: String)] = []

        // (1) SYNTAX gate (always on, cheap): a symbol whose emitted registration does not
        // even PARSE is dropped immediately (a malformed call template). This is the
        // toolchain-free floor of the net; the swiftc net below adds the type proof.
        var kept = symbols.filter { sym in
            let region = renderRegistration(sym)
            let standalone = standaloneProbe(region: region, sym: sym, appTypeStub: appTypeStub)
            if Self.parses(standalone) { return true }
            demoted.append((sym.id, sym.canonicalSignature, "registration source does not parse"))
            return false
        }

        // (2) COMPILES-OR-DEMOTE net (the load-bearing property): host-`swiftc -typecheck`
        // each surviving symbol IN ISOLATION against the app-type stub. A symbol whose
        // generated native call does not type-check (renamed/removed/private/wrong-arity)
        // is DROPPED — never reaching the developer's build. Skips (keeps all) when the host
        // toolchain is unavailable or the baseline stub itself doesn't compile (inconclusive,
        // exactly as `BridgeTypecheck` does — never spuriously demote). The net runs against
        // the SAME `target` ABI so the proof matches what's emitted.
        if let validate {
            let net = validate.run(symbols: kept, appTypeStub: appTypeStub, target: target)
            if net.ran {
                for sym in kept where net.failing.contains(sym.id) {
                    demoted.append((sym.id, sym.canonicalSignature,
                                    "generated native call did not type-check against the app's real types"))
                }
                kept = kept.filter { !net.failing.contains($0.id) }
            }
        }

        let file = kept.isEmpty ? "" : renderFile(symbols: kept)
        return Result(fileContents: file,
                      emittedSymbolIDs: kept.map { $0.id }.sorted(),
                      demoted: demoted)
    }

    // MARK: - Cheap syntax check (mirrors ThunkGenerator.parses)

    /// Parse a generated source and report whether SwiftSyntax saw NO error tokens.
    public static func parses(_ source: String) -> Bool {
        !Parser.parse(source: source).hasError
    }

    // MARK: - File rendering

    /// Render the whole generated file: imports + the registration function whose body
    /// registers each kept symbol's closure with the host-bridge registry, each inside its
    /// own BEGIN/END region. Dispatches on `target` (stub shim vs the real SDK API).
    func renderFile(symbols: [RoutedSymbol]) -> String {
        // Union of every symbol's required imports (de-duped, sorted), each `#if canImport`-
        // guarded so a missing module never breaks the file — exactly the SwiftUI thunk file's
        // import discipline.
        var extra = Set<String>()
        for s in symbols { extra.formUnion(s.requiredImports) }
        extra.subtract(["Foundation", "PatchSDK", "PatchHostBridge"])

        var out = """
        // PatchHostBridges.generated.swift — GENERATED BY `patchcli prepare`. DO NOT EDIT.
        // @generated
        // =========================================================================
        // AUTOGENERATED FILE — DO NOT EDIT BY HAND OR WITH AN AI CODING ASSISTANT.
        //
        // This file is regenerated on every `patchcli prepare` run (which also runs
        // automatically inside `patchcli build`/`push`/`release`). Any manual edit
        // here is SILENTLY OVERWRITTEN on the next prepare. An inconsistent bridge
        // table can break the OTA host bridge (causing runtime failures or crashes).
        //
        // To change bridge behaviour: update the source symbol or host-bridge config
        // and re-run `patchcli prepare`. To regenerate from scratch, delete this
        // file and run `patchcli prepare`.
        // =========================================================================
        // The compiled-in dispatch table for the generalized "call what's already linked"
        // host bridge (DESIGN §4.2). For each native symbol the engine chose to route, a
        // closure that DECODES the TLV args, calls the REAL native symbol directly, and
        // ENCODES the TLV result — registered with the SDK host-bridge registry by id. The
        // SDK serves `patch_host.call(symbolId, …)` by looking the closure up.
        //
        // App-Store-clean: these are STATICALLY TYPE-CHECKED native calls compiled into your
        // app (no `dlsym`, no ObjC-runtime lookup). Only DATA changes at runtime, never code.
        // A symbol that no longer compiles against your types was DROPPED at `patchcli build`
        // (the routed call stayed native) — it can never break this file.
        //
        // Regenerated wholesale on every `patchcli prepare`. Safe to delete this whole folder.

        import Foundation

        """
        switch target {
        case .stubShim:
            out += "import PatchSDK\n"
        case .realSDK:
            // The real SDK host runtime lives in the `PatchHostBridge` SwiftPM target.
            out += "import PatchHostBridge\n"
        }
        out += "\n"
        for imp in extra.sorted() {
            out += "#if canImport(\(imp))\nimport \(imp)\n#endif\n"
        }
        out += "\n"
        out += "/// Register every routed native symbol with the host-bridge registry.\n"
        out += "/// Called ONCE by the SDK at bridge bootstrap (idempotent — `register` overwrites by id).\n"
        out += "@inline(never)\n"
        switch target {
        case .stubShim:
            out += "func \(Self.registerFunctionName)() {\n"
        case .realSDK:
            // The real registry is an INSTANCE (`PatchHostBridge` is a class); the SDK passes
            // its controller in (DESIGN §4.2 — registration is keyed by the engine's symbol id).
            out += "func \(Self.registerFunctionName)(into bridge: PatchHostBridge) {\n"
        }
        if symbols.isEmpty {
            out += "    // No routed symbols.\n"
        }
        for sym in symbols.sorted(by: { $0.id < $1.id }) {
            out += renderRegistration(sym)
        }
        out += "}\n"
        return out
    }

    /// Render ONE routed symbol's registration region: a BEGIN/END-isolated `register(...)`
    /// call whose closure decodes args, invokes the real native call, and encodes the result.
    /// This is the per-symbol unit the compiles-or-demote net isolates. Dispatches on `target`.
    func renderRegistration(_ sym: RoutedSymbol) -> String {
        switch target {
        case .stubShim: return renderRegistrationStub(sym)
        case .realSDK:  return renderRegistrationRealSDK(sym)
        }
    }

    // ---- stub-shim ABI (the original standalone shape; the unit tests pin it) ----

    private func renderRegistrationStub(_ sym: RoutedSymbol) -> String {
        var out = "    " + Self.beginRegion(sym.id) + "\n"
        out += "    // \(sym.canonicalSignature)\n"
        // Async symbols use `registerAsync` + an `async` closure; the call is `await …`.
        // Throwing symbols wrap the encode in `do/catch → .error` (the demote channel).
        let registerFn = sym.isAsync ? "registerAsync" : "register"
        let closureEffects = sym.isAsync ? "async throws" : "throws"   // async ⇒ async throws
        out += "    PatchHostBridge.\(registerFn)(id: \(sym.id), signature: \(Self.quote(sym.canonicalSignature))) { (__a: PatchBridgeArgs) \(closureEffects) -> PatchBridgeValue in\n"
        let call = Self.callExpr(Self.substituteArgsStub(sym.callTemplate, argTypes: sym.argTypes), sym: sym)
        out += renderEncodeBody(sym: sym, call: call, indent: "        ", retainPrefix: "__a.retain")
        out += "    }\n"
        out += "    " + Self.endRegion(sym.id) + "\n"
        return out
    }

    // ---- REAL SDK ABI (the retargeted production shape — DESIGN §4.2 / the integration
    // contract). `bridge.register(id:signature:) { (args: ArgReader, handles: HandleTable)
    // throws -> TLVValue in … }`. A handle arg is RESOLVED + guarded (optional cast → throw
    // → tagged `.error`); a returned reference type is RETAINED on the handle table. ----

    private func renderRegistrationRealSDK(_ sym: RoutedSymbol) -> String {
        var out = "    " + Self.beginRegion(sym.id) + "\n"
        out += "    // \(sym.canonicalSignature)\n"
        // Async symbols register via `registerAsync` + an `async` closure (the SDK resumes
        // them from the pump stall); throwing symbols wrap the encode in `do/catch → .error`.
        let registerFn = sym.isAsync ? "registerAsync" : "register"
        let closureEffects = sym.isAsync ? "async throws" : "throws"
        out += "    bridge.\(registerFn)(id: \(sym.id), signature: \(Self.quote(sym.canonicalSignature))) { (args: ArgReader, handles: HandleTable) \(closureEffects) -> TLVValue in\n"
        // A handle arg needs a `guard let` binding BEFORE the call expression (the resolve is
        // an Optional). Emit those bindings, then the call expression substituting each arg.
        var preamble = ""
        for (k, t) in sym.argTypes.enumerated() {
            if case .handle(let ty) = t {
                preamble += "        guard let __h\(k) = handles.resolve(try args.handle(\(k)), as: \(ty).self) else {\n"
                preamble += "            return .error(\"stale/invalid handle for arg \(k)\")\n"
                preamble += "        }\n"
            }
        }
        out += preamble
        let call = Self.callExpr(Self.substituteArgsRealSDK(sym.callTemplate, argTypes: sym.argTypes), sym: sym)
        out += renderEncodeBody(sym: sym, call: call, indent: "        ", retainPrefix: "handles.retain")
        out += "    }\n"
        out += "    " + Self.endRegion(sym.id) + "\n"
        return out
    }

    // MARK: - Shared call-expression + result-encode rendering (sync / throwing / async)

    /// Decorate the substituted native call with the right effect prefixes in the canonical
    /// Swift order: `try await …` for `async throws`, `await …` for `async`, `try …` for
    /// `throws` (Swift requires `try` to PRECEDE `await`). The `try` is what arms the
    /// `do/catch → .error` wrapper `renderEncodeBody` emits.
    static func callExpr(_ substituted: String, sym: RoutedSymbol) -> String {
        var c = substituted
        if sym.isAsync { c = "await " + c }
        if sym.isThrowing { c = "try " + c }
        return c
    }

    /// Render the encode-and-return body for one symbol's closure: encode `call`'s result as
    /// the matching `TLVValue`, returning it. For a THROWING symbol the whole body is wrapped
    /// in `do { return <encode> } catch { return .error("\(error)") }` — the `.error` tag is
    /// the demote channel, so a thrown native error routes the guest to its native fallback
    /// (never a crash, never a wrong value). `retainPrefix` is the handle-retain call for the
    /// active ABI (`__a.retain` for the stub, `handles.retain` for the real SDK).
    func renderEncodeBody(sym: RoutedSymbol, call: String, indent: String, retainPrefix: String) -> String {
        // The single `return <TLV>` (or, for void, the call statement + `return .nilValue`).
        func encodeLines(_ ind: String) -> String {
            switch sym.returnType {
            case .void:   return "\(ind)\(call)\n\(ind)return .nilValue\n"
            case .int:    return "\(ind)return .i64(Int64(\(call)))\n"
            case .double: return "\(ind)return .f64(Double(\(call)))\n"
            case .bool:   return "\(ind)return .bool(\(call))\n"
            case .string: return "\(ind)return .string(\(call))\n"
            case .data:   return "\(ind)return .bytes(Array(\(call)))\n"
            case .handle: return "\(ind)return .handle(\(retainPrefix)(\(call)))\n"
            }
        }
        guard sym.isThrowing else { return encodeLines(indent) }
        // Throwing: wrap in do/catch → .error (the demote channel). The native call itself is
        // `try …` (or `await try …`); ANY thrown error becomes a tagged `.error` result.
        var out = "\(indent)do {\n"
        out += encodeLines(indent + "    ")
        out += "\(indent)} catch {\n"
        out += "\(indent)    return .error(\"\\(error)\")\n"
        out += "\(indent)}\n"
        return out
    }

    // MARK: - Static back-compat wrappers (stub-mode; the unit tests call these)

    /// Stub-mode registration rendering (back-compat for the standalone unit tests).
    static func renderRegistration(_ sym: RoutedSymbol) -> String {
        HostBridgeThunkGenerator(target: .stubShim).renderRegistrationStub(sym)
    }

    /// Stub-mode arg substitution (back-compat).
    static func substituteArgs(_ template: String, argTypes: [ArgType]) -> String {
        substituteArgsStub(template, argTypes: argTypes)
    }

    /// Substitute each `\u{1}k\u{1}` placeholder with a typed TLV decode of arg k against the
    /// STUB shim (`__a.f64`/`Int(__a.i64)`/`__a.str`/`__a.object(_:as:)`).
    static func substituteArgsStub(_ template: String, argTypes: [ArgType]) -> String {
        var out = template
        for (k, t) in argTypes.enumerated() {
            let decode: String
            switch t {
            case .int:           decode = "Int(try __a.i64(\(k)))"
            case .double:        decode = "try __a.f64(\(k))"
            case .bool:          decode = "try __a.bool(\(k))"
            case .string:        decode = "try __a.str(\(k))"
            case .data:          decode = "Data(try __a.bytes(\(k)))"
            case .handle(let ty): decode = "(try __a.object(\(k), as: \(ty).self))"
            }
            out = out.replacingOccurrences(of: "\u{1}\(k)\u{1}", with: decode)
        }
        return out
    }

    /// Substitute each `\u{1}k\u{1}` placeholder with a typed TLV decode of arg k against the
    /// REAL SDK `ArgReader`/`HandleTable` API. `int`→`Int(try args.i64(k))`,
    /// `double`→`try args.f64(k)`, `bool`→`try args.bool(k)`, `string`→`try args.string(k)`
    /// (note `string`, NOT `str`), `data`→`Data(try args.bytes(k))`, `handle(T)`→`__hk` (the
    /// pre-resolved, type-cast binding the registration emitted up front).
    static func substituteArgsRealSDK(_ template: String, argTypes: [ArgType]) -> String {
        var out = template
        for (k, t) in argTypes.enumerated() {
            let decode: String
            switch t {
            case .int:     decode = "Int(try args.i64(\(k)))"
            case .double:  decode = "try args.f64(\(k))"
            case .bool:    decode = "try args.bool(\(k))"
            case .string:  decode = "try args.string(\(k))"
            case .data:    decode = "Data(try args.bytes(\(k)))"
            case .handle:  decode = "__h\(k)"   // the guarded binding from the preamble
            }
            out = out.replacingOccurrences(of: "\u{1}\(k)\u{1}", with: decode)
        }
        return out
    }

    /// Wrap a string as a Swift double-quoted literal (the canonical signature carried as a
    /// comment + the registration key). Escapes backslash and quote — the signature is a
    /// demangled identifier string so this is sufficient.
    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Build the STANDALONE probe source for ONE symbol — the per-symbol unit the net
    /// type-checks in isolation: the app-type stub + the minimal registry shim (for the
    /// active `target`) + the symbol's single registration. A symbol that type-checks here is
    /// build-safe against the app's real types; one that doesn't is demoted.
    func standaloneProbe(region: String, sym: RoutedSymbol, appTypeStub: String) -> String {
        var imports = ""
        for imp in Set(sym.requiredImports).subtracting(["Foundation"]).sorted() {
            imports += "#if canImport(\(imp))\nimport \(imp)\n#endif\n"
        }
        let shim = target == .realSDK ? Self.realSDKRegistryShim : Self.registrySDKShim
        // The real-SDK registration is `bridge.register(...)` — give the probe a local
        // `bridge` of the shimmed `PatchHostBridge` type so the call type-checks standalone.
        let bridgeDecl = target == .realSDK ? "let bridge = PatchHostBridge()\n" : ""
        return """
        import Foundation
        \(imports)\(shim)
        \(appTypeStub)
        func __probe_\(sym.id < 0 ? "n\(-sym.id)" : "\(sym.id)")() {
        \(bridgeDecl)\(region)
        }
        """
    }

    // =============================================================================
    // MARK: - STUBBED INTEGRATION INTERFACES (see doc sections at bottom)
    // =============================================================================

    /// `HostBridgeRegistryAPI` (the SDK-host agent owns the REAL one). The minimal `PatchSDK`
    /// surface the GENERATED file calls — emitted as a SHIM into the type-check probe so the
    /// net can prove the generated registration's TYPE soundness WITHOUT the real SDK package
    /// (exactly as `BridgeTypecheck.patchSDKShim` does for the native-shell bridges).
    ///
    /// The real SDK MUST provide a `PatchSDK` module exporting these EXACT shapes:
    ///   * `enum PatchBridgeValue` — the host-side TLV value (the prototype's `HostValue`):
    ///     `.nilValue/.i64/.f64/.bool/.string/.bytes/.handle/.error`.
    ///   * `struct PatchBridgeArgs` — the decoded arg vector + handle-table accessors:
    ///     `i64(_:) throws -> Int64`, `f64(_:) throws -> Double`, `bool(_:) throws -> Bool`,
    ///     `str(_:) throws -> String`, `bytes(_:) throws -> [UInt8]`,
    ///     `object<T>(_:as:) throws -> T` (resolve a handle arg + cast),
    ///     `retain(_ obj: AnyObject) -> Int32` (handle-table retain for a returned ref type).
    ///   * `enum PatchHostBridge { static func register(id: Int32, signature: String,
    ///        _ thunk: @escaping (PatchBridgeArgs) throws -> PatchBridgeValue) }` — the registry.
    /// The closure shape + label names here are the integration contract.
    static let registrySDKShim = """
    // Synthesized PatchSDK host-bridge shim — host type-check only, never shipped. DO NOT EDIT.
    public enum PatchBridgeValue {
        case nilValue
        case i64(Int64)
        case f64(Double)
        case bool(Bool)
        case string(String)
        case bytes([UInt8])
        case handle(Int32)
        case error(String)
    }
    public struct PatchBridgeArgs {
        public func i64(_ i: Int) throws -> Int64 { 0 }
        public func f64(_ i: Int) throws -> Double { 0 }
        public func bool(_ i: Int) throws -> Bool { false }
        public func str(_ i: Int) throws -> String { "" }
        public func bytes(_ i: Int) throws -> [UInt8] { [] }
        public func object<T>(_ i: Int, as: T.Type) throws -> T { fatalError() }
        public func retain(_ obj: AnyObject) -> Int32 { 0 }
    }
    public enum PatchHostBridge {
        public static func register(id: Int32, signature: String,
                                    _ thunk: @escaping (PatchBridgeArgs) throws -> PatchBridgeValue) {}
        // ASYNC routed symbols (DESIGN §8.7): an `async (throws)` thunk the SDK resumes from
        // the pump stall. Same id/signature keying; the closure is `async throws`.
        public static func registerAsync(id: Int32, signature: String,
                                         _ thunk: @escaping (PatchBridgeArgs) async throws -> PatchBridgeValue) {}
    }
    """

    /// Static back-compat probe builder (stub-mode; the unit tests call this statically).
    static func standaloneProbe(region: String, sym: RoutedSymbol, appTypeStub: String) -> String {
        HostBridgeThunkGenerator(target: .stubShim)
            .standaloneProbe(region: region, sym: sym, appTypeStub: appTypeStub)
    }

    /// The REAL-SDK host-bridge shim — a faithful, byte-for-byte type mirror of
    /// `sdk/Sources/PatchHostBridge` (`TLVValue` / `ArgReader` / `HandleTable` /
    /// `final class PatchHostBridge`). The compiles-or-demote net type-checks the
    /// real-API thunk against THIS, so a generated `bridge.register(id:signature:) {
    /// (args, handles) in … }` is proven build-safe against the same shapes the SDK
    /// actually exports. (Synthesized for the host type-check only — the SHIPPED file
    /// `import PatchHostBridge`s the real module; this shim is never shipped.)
    ///
    /// These shapes ARE the integration contract — they MUST stay identical to the SDK's
    /// `PatchHostBridge` target. If the SDK changes the register signature / accessor names,
    /// update both this shim AND `renderRegistrationRealSDK` / `substituteArgsRealSDK`.
    static let realSDKRegistryShim = """
    // Synthesized PatchHostBridge shim — mirrors sdk/Sources/PatchHostBridge. Type-check only.
    public enum TLVValue {
        case nilValue
        case i64(Int64)
        case f64(Double)
        case bool(Bool)
        case string(String)
        case bytes([UInt8])
        case handle(Int32)
        case error(String)
    }
    public struct ArgReader {
        public func requireArity(_ n: Int) throws {}
        public func f64(_ i: Int) throws -> Double { 0 }
        public func i64(_ i: Int) throws -> Int64 { 0 }
        public func bool(_ i: Int) throws -> Bool { false }
        public func string(_ i: Int) throws -> String { "" }
        public func bytes(_ i: Int) throws -> [UInt8] { [] }
        public func handle(_ i: Int) throws -> Int32 { 0 }
    }
    public final class HandleTable {
        public init() {}
        public func retain(_ obj: AnyObject) -> Int32 { 0 }
        public func resolve(_ id: Int32) -> AnyObject? { nil }
        public func resolve<T>(_ id: Int32, as type: T.Type) -> T? { nil }
    }
    public final class PatchHostBridge {
        public init() {}
        @discardableResult
        public func register(id: Int32, signature: String = "",
                             _ thunk: @escaping (ArgReader, HandleTable) throws -> TLVValue) -> PatchHostBridge { self }
        // ASYNC routed symbols (DESIGN §8.7): mirrors the SDK's `registerAsync`. The closure
        // is `async throws`; the SDK runs it from the pump stall + resumes the guest.
        @discardableResult
        public func registerAsync(id: Int32, signature: String = "",
                                  _ thunk: @escaping (ArgReader, HandleTable) async throws -> TLVValue) -> PatchHostBridge { self }
    }
    """
}

// =============================================================================
// MARK: - The compiles-or-demote net (BridgeTypecheck precedent, per-symbol isolation)
// =============================================================================

/// Host-`swiftc -typecheck` net for the generated host-bridge thunks — the production
/// compiles-or-demote mechanism (DESIGN §4.2 / §6). For each routed symbol, type-check its
/// generated registration IN ISOLATION (its own probe file) against the app-type stub +
/// the registry shim, and report which ids FAIL (→ the generator DROPS them). Modeled on
/// `Compiler.BridgeTypecheck`: skip (keep all — never spuriously demote) when the host
/// toolchain is unavailable or the baseline (stub + shim) doesn't compile on its own.
///
/// Lives here (CodeGenerator) rather than in Compiler so the generator + its net are one
/// unit and testable standalone; the BuildPipeline wires the real app-source stub in at
/// integration (the same place it wires `BridgeTypecheck`).
public struct BridgeThunkValidator {
    public init() {}

    public struct Outcome {
        /// Ids whose generated thunk FAILED to type-check against the app types (demote).
        public var failing: Set<Int32> = []
        /// Whether the net actually ran (false = toolchain unavailable / inconclusive baseline).
        public var ran: Bool = false
        public var note: String = ""
    }

    /// Run the net over `symbols` against `appTypeStub` (the developer's real types, or a
    /// stub of them). `target` selects the registration ABI proven (stub shim vs the real
    /// SDK). When the host `swiftc` is unavailable, or the baseline (stub + registry shim)
    /// doesn't compile on its own, returns `ran == false` (keep all — inconclusive).
    public func run(symbols: [RoutedSymbol], appTypeStub: String,
                    target: HostBridgeThunkGenerator.RegistrationTarget = .stubShim) -> Outcome {
        var out = Outcome()
        guard !symbols.isEmpty else { out.note = "no symbols"; return out }
        guard let swiftc = Self.hostSwiftc() else {
            out.note = "host swiftc unavailable — skipped (keep all)"; return out
        }
        let gen = HostBridgeThunkGenerator(target: target)
        let shim = target == .realSDK
            ? HostBridgeThunkGenerator.realSDKRegistryShim
            : HostBridgeThunkGenerator.registrySDKShim
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("patch-hostbridgecheck-\(UUID().uuidString)")
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        // BASELINE: the app-type stub + the registry shim must type-check on their own. If
        // not (a stub that references an unresolvable import), the net is inconclusive →
        // skip (never spuriously demote) — exactly `BridgeTypecheck`'s safety valve.
        let baseline = """
        import Foundation
        \(shim)
        \(appTypeStub)
        """
        let baseURL = work.appendingPathComponent("Baseline.swift")
        try? baseline.write(to: baseURL, atomically: true, encoding: .utf8)
        if Self.typecheckFails(swiftc: swiftc, file: baseURL, attributableTo: nil) {
            out.note = "app-type baseline did not type-check — inconclusive, skipped (keep all)"
            return out
        }
        out.ran = true

        // Per-symbol isolation: type-check each symbol's probe alone so one bad symbol never
        // condemns a good one (mirrors `BridgeTypecheck`'s per-bridge loop + the SwiftUI
        // per-view isolation).
        for sym in symbols {
            let probe = gen.standaloneProbe(
                region: gen.renderRegistration(sym), sym: sym, appTypeStub: appTypeStub)
            let url = work.appendingPathComponent("Probe_\(sym.id < 0 ? "n\(-sym.id)" : "\(sym.id)").swift")
            try? probe.write(to: url, atomically: true, encoding: .utf8)
            if Self.typecheckFails(swiftc: swiftc, file: url, attributableTo: url) {
                out.failing.insert(sym.id)
            }
        }
        out.note = out.failing.isEmpty
            ? "all \(symbols.count) host-bridge thunk(s) type-checked"
            : "\(out.failing.count)/\(symbols.count) host-bridge thunk(s) failed host type-check — demoted"
        return out
    }

    /// Locate the host `swiftc` (Apple/Xcode toolchain, NOT the WASM toolchain) — same
    /// resolution as `BridgeTypecheck.hostSwiftc`.
    static func hostSwiftc() -> URL? {
        let xcrun = Process()
        xcrun.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        xcrun.arguments = ["-f", "swiftc"]
        let pipe = Pipe()
        xcrun.standardOutput = pipe
        xcrun.standardError = Pipe()
        if (try? xcrun.run()) != nil {
            xcrun.waitUntilExit()
            if xcrun.terminationStatus == 0,
               let data = try? pipe.fileHandleForReading.readToEnd(),
               let path = String(data: data ?? Data(), encoding: .utf8)?
                   .trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty, FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        for p in ["/usr/bin/swiftc", "/usr/local/bin/swiftc"] where FileManager.default.fileExists(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        return nil
    }

    /// `swiftc -typecheck` one probe file. Returns true if it FAILS. When `attributableTo` is
    /// non-nil, a failure counts only if the compiler error mentions that file (defensive —
    /// the probe is the only non-baseline file, so this always holds, but we mirror
    /// `BridgeTypecheck`'s attribution).
    static func typecheckFails(swiftc: URL, file: URL, attributableTo: URL?) -> Bool {
        let p = Process()
        p.executableURL = swiftc
        p.arguments = ["-typecheck", "-parse-as-library", "-suppress-warnings", file.path]
        let errPipe = Pipe()
        p.standardOutput = Pipe()
        p.standardError = errPipe
        guard (try? p.run()) != nil else { return false }  // can't run → don't demote
        let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
        p.waitUntilExit()
        guard p.terminationStatus != 0 else { return false }
        guard let attributableTo else { return true }
        let log = String(data: errData ?? Data(), encoding: .utf8) ?? ""
        return log.contains(attributableTo.lastPathComponent)
    }
}

// =============================================================================
// MARK: - INTEGRATION NOTES (for the reconnection at integration)
// =============================================================================
//
// This generator emits against two parallel-agent-owned surfaces. We define the precise
// shapes it expects here (above) + stub them so the generator compiles + tests standalone.
// At integration, swap the stubs for the real types — the generated SOURCE doesn't change.
//
// ── ABI CORE (owned by the "ABI core" agent: TLVTag / HostBridgeSymbol / symbol-id) ──
//   * `RoutedSymbol.id` is the content-addressed `truncate32(SHA256(canonicalSignature))`
//     the ABI-core agent computes (DESIGN §2.3). The generator treats it opaquely (keys the
//     registration + per-symbol region by it). When the ABI-core `HostBridgeSymbol` lands,
//     the engine's classifier maps each routed call site → a `RoutedSymbol` (its `id` =
//     the ABI-core symbol-id; `argTypes`/`returnType` mirror the ABI-core `argTags[]`/`retTag`
//     in §2.3's manifest). The generator's `ArgType`/`ReturnType` are the Swift-source-level
//     view (which DECODE to emit); the ABI-core `TLVTag` is the WIRE view (the byte format).
//     They are 1:1: int↔i64, double↔f64, bool↔bool, string↔string, data↔bytes, handle↔handle.
//     If the ABI-core agent exposes `TLVTag`, replace `ArgType`/`ReturnType` with thin
//     wrappers over it (keep the Swift-decode mapping in `substituteArgs`).
//
// ── SDK HOST REGISTRATION (owned by the "SDK host" agent) ──
//   The generated file calls `PatchHostBridge.register(id:signature:_:)` and, inside each
//   closure, `PatchBridgeArgs` decode accessors + `.retain(_:)`, returning a
//   `PatchBridgeValue`. The SDK MUST export a `PatchSDK` module with EXACTLY these shapes
//   (see `HostBridgeThunkGenerator.registrySDKShim` — that shim IS the contract). The SDK's
//   bridge bootstrap calls `__patchRegisterHostBridges()` once; thereafter it serves
//   `patch_host.call(symbolId, argsBlob)` by: decode argsBlob → `PatchBridgeArgs`, look up
//   the closure by id, invoke it, encode the returned `PatchBridgeValue` → resultBlob (a
//   thrown error → `.error` → the guest demotes). The handle table (`retain`/`object(_:as:)`/
//   release) is the SDK's, proven in `experiments/host-bridge-generalized`.
//
// ── FOLLOW-UPS (explicitly out of scope, per task) ──
//   * FINGERPRINT GATING (DESIGN §5): fold `Result.emittedSymbolIDs` (the routed-symbol set)
//     into the native-shell fingerprint so a patch routing a symbol absent from the target
//     build is gated out BEFORE it ships, not just demoted at runtime. SKIPPED for closed
//     internal testing — the runtime demote net (have()==0 / tagged .error) is the safety
//     floor meanwhile.
//   * The engine-side CLASSIFIER (DESIGN §4.1) that produces `[RoutedSymbol]` from routable
//     call sites is the OTHER half of part B — this generator consumes its output.
//   * BuildPipeline wiring: write `Result.fileContents` into `Patch/Generated/`, add it to
//     the app target (alongside the SwiftUI thunk file), run `BridgeThunkValidator` with the
//     real dev source as `appTypeStub`, and log `Result.demoted`.
