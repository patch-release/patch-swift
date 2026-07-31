// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Categories of native symbols, mirroring the plan's table.
public enum NativeCategory: String, Sendable, Codable, CaseIterable, Hashable {
    case uiKitSwiftUI = "UIKit/SwiftUI"
    case systemFrameworks = "System Frameworks"
    case networking = "Networking"
    case storage = "Storage"
    case concurrency = "Concurrency Primitives"
    case objcInterop = "ObjC Interop"
    case cInterop = "C Interop"
    case keychain = "Keychain"
    case notifications = "Notifications"
    case appLifecycle = "App Lifecycle"
    case graphicsMedia = "Graphics & Media"
    case sensorsLocation = "Sensors & Location"
    case systemServices = "System Services"
    /// Foundation value types that compile under the full WASM SDK (Day-2 finding).
    case wasmSafeFoundation = "WASM-safe Foundation"
}

/// The execution tier of a registered symbol. Day-2 replaces the Day-1 binary
/// native/not split with a three-way tier that drives the classifier.
///
///  - `.mustStayNative`  — safety-critical; forces the function `native`. Zero
///    false negatives: any of these in the closure means native, no exceptions.
///  - `.bridgeable`      — a host bridge exists/planned; the function can run OTA
///    by calling `Patch.call(...)` into the native bridge → `bridged`.
///  - `.wasmSafeFoundation` — Foundation value types proven to compile to WASM
///    under the full SDK (Decimal/Date/Codable/etc.). These are NOT native;
///    they live in the registry only so the classifier can *recognise* them as
///    WASM-eligible rather than treating an unknown capitalised name as native.
public enum SymbolTier: String, Sendable, Codable, Hashable, CaseIterable {
    case mustStayNative
    case bridgeable
    case wasmSafeFoundation
}

/// A single native symbol entry.
public struct NativeSymbol: Sendable, Codable, Hashable {
    /// The symbol name as it appears in source: a type (`URLSession`), a member
    /// (`UserDefaults.standard`), a global function (`SecItemAdd`), or an
    /// attribute (`@State`).
    public let symbol: String
    public let category: NativeCategory
    /// Why this requires native execution (for reports).
    public let reason: String
    /// The execution tier (Day-2). Drives the classifier.
    public let tier: SymbolTier

    /// Whether Patch ships a pre-built bridge for this symbol. A bridged native
    /// call lets a function be classified `bridged` rather than `native`.
    /// Derived from the tier (`.bridgeable`), kept for source/report compatibility.
    public var hasBridge: Bool { tier == .bridgeable }
    /// True iff this symbol forces a function native (tier 1).
    public var forcesNative: Bool { tier == .mustStayNative }
    /// True iff this symbol is WASM-eligible Foundation (tier 3, not native).
    public var isWasmSafe: Bool { tier == .wasmSafeFoundation }

    public init(symbol: String, category: NativeCategory, reason: String, tier: SymbolTier) {
        self.symbol = symbol
        self.category = category
        self.reason = reason
        self.tier = tier
    }

    /// Back-compat initializer (Day-1 call sites). `hasBridge` maps to a tier.
    public init(symbol: String, category: NativeCategory, reason: String, hasBridge: Bool = false) {
        self.init(symbol: symbol, category: category, reason: reason,
                  tier: hasBridge ? .bridgeable : .mustStayNative)
    }
}

/// The registry of symbols requiring native execution.
///
/// Agent A2 scope. Lookup is by exact symbol *and* by the leading type of a
/// member access (e.g. both `URLSession` and `URLSession.shared` resolve to the
/// `URLSession` entry). The classifier consults this for every reference in a
/// function's transitive closure.
///
/// The registry is populated from `NativeRegistry+Entries.swift` (categorized).
public struct NativeRegistry: Sendable {
    /// All entries, keyed by symbol name for O(1) lookup.
    private let bySymbol: [String: NativeSymbol]
    public let allSymbols: [NativeSymbol]

    public init(symbols: [NativeSymbol]) {
        self.allSymbols = symbols
        var map: [String: NativeSymbol] = [:]
        for s in symbols { map[s.symbol] = s }
        self.bySymbol = map
    }

    /// The default registry, populated with the full categorized entry set.
    public static let standard = NativeRegistry(symbols: NativeRegistry.standardEntries)

    public var count: Int { allSymbols.count }

    public func counts(by category: NativeCategory) -> Int {
        allSymbols.lazy.filter { $0.category == category }.count
    }

    /// Number of entries in a given tier (for reports).
    public func counts(by tier: SymbolTier) -> Int {
        allSymbols.lazy.filter { $0.tier == tier }.count
    }

    /// Look up a symbol name directly.
    public func entry(for symbol: String) -> NativeSymbol? {
        bySymbol[symbol]
    }

    /// Resolve a reference to a native symbol, if any.
    ///
    /// Checks, in order:
    ///   1. The reference's own name (`URLSession`, `SecItemAdd`, `@State`).
    ///   2. The base of a member access (`URLSession` from `URLSession.shared`).
    ///   3. Attribute names without the leading `@`.
    public func match(_ reference: Reference) -> NativeSymbol? {
        if let hit = bySymbol[reference.name] { return hit }
        if let base = reference.base, let hit = bySymbol[base] { return hit }
        // Attributes are stored without "@" in the entry table.
        if reference.kind == .attribute {
            let stripped = reference.name.hasPrefix("@")
                ? String(reference.name.dropFirst()) : reference.name
            if let hit = bySymbol[stripped] { return hit }
            if let hit = bySymbol["@" + stripped] { return hit }
        }
        return nil
    }

    /// Is the symbol name registered AND not WASM-safe (i.e. tier 1 or tier 2)?
    /// WASM-safe Foundation symbols are registered but are NOT native, so they
    /// return `false` here. Used by the splitter to decide which statements must
    /// stay in/route through the native shell.
    public func isNative(_ symbol: String) -> Bool {
        guard let s = bySymbol[symbol] else { return false }
        return s.tier != .wasmSafeFoundation
    }

    /// The tier of a reference, if the registry knows it. `nil` => unknown
    /// symbol (the classifier treats unknown calls/types conservatively).
    public func tier(of reference: Reference) -> SymbolTier? {
        match(reference)?.tier
    }
}
