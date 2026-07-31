// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The kind of a parsed function-like declaration.
public enum FunctionKind: String, Sendable, Codable, Hashable {
    case function          // free function or static/global func
    case method            // instance/type method on a type
    case initializer       // init(...)
    case computedProperty  // var x: T { ... } with a body
    case closure           // closure literal { ... }
    case accessor          // get/set/willSet/didSet accessor block
}

/// A single symbol reference discovered inside a function body.
///
/// References are intentionally *coarse*: we capture the textual name plus a
/// best-effort kind. The classifier treats anything it cannot resolve as
/// potentially native (the conservative default), so over-capturing here is
/// always safe — it can only ever reduce OTA coverage, never break safety.
public struct Reference: Sendable, Codable, Hashable {
    public enum ReferenceKind: String, Sendable, Codable, Hashable {
        case typeName        // e.g. `URLSession`, `OrderSummary`
        case functionCall    // e.g. `validateOrder(...)`
        case memberAccess    // e.g. `URLSession.shared`, `.standard`
        case identifier      // bare identifier reference
        case attribute       // e.g. `@State`, `@objc`
        case selector        // `#selector(...)`
    }

    public let name: String
    public let kind: ReferenceKind
    /// The base of a member access if known (e.g. for `URLSession.shared`, base = "URLSession").
    public let base: String?
    public let line: Int

    public init(name: String, kind: ReferenceKind, base: String? = nil, line: Int) {
        self.name = name
        self.kind = kind
        self.base = base
        self.line = line
    }
}

/// A reactive/stored property that a member READS and the native shell can
/// HOST-PROJECT into a plain marshalled value before calling the lifted WASM
/// fragment (the same trick the SwiftUI view-body path uses for `@State`).
///
/// Only populated for a member that is "pure-logic-over-reactive-reads": it
/// would have been forced native ONLY because it reads reactive/stored
/// properties, but it writes nothing, touches no other native interop, returns
/// a marshallable value type, and every property it reads is itself a
/// marshallable value type. The native shell reads `self.<name>`, marshals it
/// into the fragment, and the fragment runs the pure logic over the projected
/// value — it never touches reactive state. See `FunctionExtractor`'s
/// host-projection gate and `FunctionSplitter.strategyHostProjection`.
public struct HostProjectableRead: Sendable, Codable, Hashable {
    /// The property name the member reads (e.g. `connections`, `isPro`).
    public let name: String
    /// The property's declared value type (e.g. `Bool`, `String`, `[Int]`),
    /// proven marshallable at extraction time. Threaded to the splitter as the
    /// fragment input's concrete type.
    public let type: String

    public init(name: String, type: String) {
        self.name = name
        self.type = type
    }
}

/// A parsed function-like declaration with everything the engine needs to
/// build a call graph and classify it.
public struct FunctionRecord: Sendable, Codable, Hashable, Identifiable {
    /// Fully-qualified, signature-bearing id, e.g.
    /// `"OrderApp.OrderService.submitOrder(_:)"`.
    public let id: String
    public let kind: FunctionKind
    public let sourceFile: URL
    public let startLine: Int
    public let endLine: Int
    public let bodyReferences: [Reference]

    /// Flags raised during parsing that *force* a native classification later,
    /// regardless of references (e.g. `@objc`, `#selector`, `dynamic`).
    public let forcesNative: Bool
    /// Human-readable reasons for `forcesNative` (for reporting / debugging).
    public let nativeFlags: [String]

    /// Reactive/stored properties this member reads that the native shell can
    /// host-project into marshalled values (the "pure-logic-over-reactive-reads"
    /// lift). Non-empty ONLY for a member that is otherwise pure/liftable and
    /// whose every reactive read is a value-marshallable type — see
    /// `HostProjectableRead`. When non-empty, the classifier routes the member to
    /// `mixed` (host-projectable, not pure `wasmEligible` — the reads need
    /// projection) and the splitter realizes the projection. Empty = no
    /// host-projection (unchanged behaviour).
    public let hostProjectableReads: [HostProjectableRead]

    /// Subset (b): this member reads value-marshallable reactive props (the
    /// `hostProjectableReads` above), the reactive read is its SOLE native-symbol
    /// reason, and it writes NO reactive property — BUT it is NOT a clean
    /// whole-body value projection (it returns `Void`, or it writes a NON-reactive
    /// stored property / `self.<plain>` via the shell). Such a method can still be
    /// PARTIALLY split: the native shell projects the reactive reads into locals,
    /// the pure remainder rides WASM (statement-level), and the native writes stay
    /// verbatim in the shell. Set ONLY when the whole-body projection (subset a)
    /// would NOT apply; the splitter's `strategyHostProjectionPartial` is the
    /// ground truth — if it cannot realize ≥1 sound fragment the member ships
    /// nothing OTA (native in the realized pass). Demote-safe by construction.
    public let hostProjectablePartial: Bool

    public init(
        id: String,
        kind: FunctionKind,
        sourceFile: URL,
        startLine: Int,
        endLine: Int,
        bodyReferences: [Reference],
        forcesNative: Bool = false,
        nativeFlags: [String] = [],
        hostProjectableReads: [HostProjectableRead] = [],
        hostProjectablePartial: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.sourceFile = sourceFile
        self.startLine = startLine
        self.endLine = endLine
        self.bodyReferences = bodyReferences
        self.forcesNative = forcesNative
        self.nativeFlags = nativeFlags
        self.hostProjectableReads = hostProjectableReads
        self.hostProjectablePartial = hostProjectablePartial
    }
}
