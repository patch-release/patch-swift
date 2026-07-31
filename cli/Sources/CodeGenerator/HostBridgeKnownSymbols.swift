// SPDX-License-Identifier: Apache-2.0

import Foundation

// ===========================================================================
// LEVER #2 (part B) — the CURATED KNOWN-SYMBOL TABLE (the breadth foundation).
//
// The call-site extractor (`HostBridgeCallExtractor`) types args/returns from
// SYNTAX ONLY and marks anything it cannot justify `<unresolved>` → the classifier
// demotes (demote-on-doubt). That is correct but COSTS COVERAGE for a small set of
// HIGH-FREQUENCY framework symbols whose signatures are KNOWN-AND-STABLE facts —
// `NotificationCenter.default.post(name:)`, `UserDefaults.standard.bool(forKey:)`,
// `FileManager.default.fileExists(atPath:)`, `UIApplication.shared.open(_:)`, … —
// where a `String`/`Bool`/`Int` arg or a `Bool`/`String`/`Int` return is a
// documented signature, NOT a guess.
//
// This table is the engine's CONFIDENT lookup: when a call MATCHES a curated entry
// (receiver text + method base name + arity), the extractor supplies the entry's
// resolved arg/return types + canonical receiver spelling + the resolver-thunk's
// real native call expression — BYPASSING the `<unresolved>` demote for exactly
// those symbols. It is a SMALL, hand-authored breadth foundation, parallel to the
// curated FusionRewriter leaf set, NOT a general type checker.
//
// THE INCLUSION BAR (the survey's "demote-on-doubt — confident routes only"):
//   1. LINKED IN EVERY APP that uses the feature — Foundation/UIKit symbols present
//      in the signed binary (no entitlement gate, no optional framework).
//   2. BY-VALUE / HANDLE marshallable — every arg + the return is a scalar/String/
//      Bool/Data or an opaque handle (no closure, no inout, no metatype, no
//      non-marshallable reference value the guest would have to synthesize).
//   3. CLOSURE-FREE (or handle-only) — a closure-bearing form (`DispatchQueue.async
//      { … }`) is EXCLUDED here; the body-walk's structural hazard flags still
//      demote it, and the table never routes around that.
//   4. STABLE SIGNATURE — the arg/return types are a documented framework fact, not
//      an overload we can't disambiguate from arity alone.
// When ANY of these is in doubt → the symbol is NOT in the table (the syntactic
// path's `<unresolved>` demote + the 3-layer fail-closed net still backstop).
//
// SAFETY POSTURE — ADDITIVE-ONLY. A table hit only ever UPGRADES an `<unresolved>`
// arg/return to a confident concrete type (or confirms a type the syntax already
// agreed on); it NEVER demotes a call the syntactic path would have routed, and it
// NEVER overrides a CONFLICTING concrete syntactic type (a mismatch means the call
// site doesn't fit the curated overload → leave it to the demote-on-doubt path).
// And it is downstream of every hard demote-gate (inout/closure/unsafe/metatype/
// selector), so a hazardous arg still demotes even on a curated symbol.
// ===========================================================================

public enum HostBridgeKnownSymbols {

    /// One curated, confidently-routable framework symbol.
    public struct Entry: Sendable, Equatable {
        /// The match key — the call-site RECEIVER text exactly as written
        /// (`"NotificationCenter.default"`, `"UserDefaults.standard"`,
        /// `"FileManager.default"`, `"UIApplication.shared"`), the method base name,
        /// and the arity. A bare free function uses receiver `""`.
        public let receiver: String
        public let method: String
        public let arity: Int

        /// The module-qualified canonical receiver spelling for the canonical
        /// signature (`"Foundation.NotificationCenter"`, `"UIKit.UIApplication"`),
        /// or `nil` for a bare free function.
        public let canonicalReceiver: String?
        /// The module the resolver-thunk's native call needs imported (`"UIKit"`),
        /// or `nil` when Foundation/the app module suffices.
        public let requiredModule: String?

        /// The resolved arg Swift types, in declaration order (length == `arity`).
        public let argTypes: [String]
        /// The argument labels in declaration order (a `nil` element = unlabelled).
        /// These pin the canonical signature + the resolver-thunk's call expression
        /// so an overload is matched by its label SET, not just its arity.
        public let argLabels: [String?]
        /// The resolved return type (`"Void"`, `"Bool"`, `"String"`, …).
        public let returnType: String

        /// The REAL native call expression the resolver-thunk invokes, as a template
        /// with each arg a `\u{1}k\u{1}` placeholder (the same convention
        /// `HostBridgeThunkGenerator`/`HostBridgeLowering` use). For MOST entries the
        /// wire-marshalled arg type EQUALS the native parameter type, so this is just
        /// the plain re-spell `<receiver>.<method>(label: \u{1}0\u{1}, …)` (and `nil`
        /// here — `HostBridgeLowering`'s default re-spell is correct). It is non-`nil`
        /// ONLY for an entry that needs a BOUNDARY RECONSTRUCTION — the wire carries a
        /// `String` but the native param is a richer value the thunk must rebuild
        /// natively (`Notification.Name(rawValue:)`, `URL(string:)!`). Supplying the
        /// wrapped template here keeps the resolver-thunk type-correct against the REAL
        /// linked symbol (proven by the host-`swiftc` typecheck test). `HostBridgeLowering`
        /// MUST prefer this template when present (the reconciliation seam).
        public let nativeCallTemplate: String?

        /// The classifier FORM this symbol routes as. The Foundation stateless quartet
        /// the survey names (`NotificationCenter`/`FileManager`/`UIApplication`) routes
        /// as `.foundationStateless` (so the existing form tag fires); everything else
        /// is `.freeOrStatic`.
        public let isFoundationStateless: Bool

        public init(receiver: String, method: String, arity: Int,
                    canonicalReceiver: String?, requiredModule: String?,
                    argTypes: [String], argLabels: [String?], returnType: String,
                    nativeCallTemplate: String? = nil,
                    isFoundationStateless: Bool) {
            self.receiver = receiver
            self.method = method
            self.arity = arity
            self.canonicalReceiver = canonicalReceiver
            self.requiredModule = requiredModule
            self.argTypes = argTypes
            self.argLabels = argLabels
            self.returnType = returnType
            self.nativeCallTemplate = nativeCallTemplate
            self.isFoundationStateless = isFoundationStateless
        }
    }

    // -----------------------------------------------------------------------
    // MARK: - The curated table
    //
    // Ordered by the survey's frequency × ease (the cheapest, highest-hit stateless
    // host calls first). Keyed by `<receiver>\u{1}<method>\u{1}<arity>` for O(1) lookup.
    // A symbol with multiple routable overloads (distinct arities / label sets) gets
    // one entry per overload — an arity not covered is left to demote-on-doubt.
    // -----------------------------------------------------------------------

    public static let entries: [Entry] = {
        var e: [Entry] = []

        // === NotificationCenter (survey #7, 492 hits) — post by name. ============
        // `.post(name:)` and `.post(name:object:)` are the two routable forms. The
        // `userInfo:` form carries a `[AnyHashable:Any]` dictionary — NOT by-value
        // marshallable → EXCLUDED (left to demote). The bare `Notification.Name` name
        // arg marshals as a String at the boundary (the thunk reconstructs the
        // `Notification.Name(rawValue:)`); the `object:` is a handle.
        e.append(.init(
            receiver: "NotificationCenter.default", method: "post", arity: 1,
            canonicalReceiver: "Foundation.NotificationCenter", requiredModule: nil,
            argTypes: ["String"], argLabels: ["name"], returnType: "Void",
            // BOUNDARY RECONSTRUCTION: the wire carries the name as a String; the real
            // `post(name:object:)` takes a `Notification.Name` + a required `object:`
            // (no default in the compiled Foundation interface), so the thunk rebuilds
            // the name natively and supplies `object: nil` (the survey's routable shape
            // is the no-object post; the `object:`/`userInfo:` forms stay out).
            nativeCallTemplate: "NotificationCenter.default.post(name: Notification.Name(\u{1}0\u{1}), object: nil)",
            isFoundationStateless: true))

        // === UserDefaults (survey #11, 199 hits) — already `.bridgeable`. =========
        // The stateless scalar getters/setters keyed by a String. `set(_:forKey:)` has
        // many value overloads; we route the SCALAR ones whose first arg the syntax
        // already types (Bool/Int/Double/String) — the entry pins the forKey:String +
        // the return Void. The READERS have a documented scalar return:
        //   bool(forKey:)->Bool, integer(forKey:)->Int, double(forKey:)->Double,
        //   string(forKey:)->String? (Optional — left to the syntactic path / the
        //   engine return-hint, since an Optional return needs the §3 nil tag the wire
        //   models but the curated table stays to the non-optional confident set).
        // We route the three NON-optional scalar readers + the Bool/Int/Double/String
        // setters; `string(forKey:)` (Optional return) is intentionally EXCLUDED.
        e.append(.init(
            receiver: "UserDefaults.standard", method: "bool", arity: 1,
            canonicalReceiver: "Foundation.UserDefaults", requiredModule: nil,
            argTypes: ["String"], argLabels: ["forKey"], returnType: "Bool",
            isFoundationStateless: false))
        e.append(.init(
            receiver: "UserDefaults.standard", method: "integer", arity: 1,
            canonicalReceiver: "Foundation.UserDefaults", requiredModule: nil,
            argTypes: ["String"], argLabels: ["forKey"], returnType: "Int",
            isFoundationStateless: false))
        e.append(.init(
            receiver: "UserDefaults.standard", method: "double", arity: 1,
            canonicalReceiver: "Foundation.UserDefaults", requiredModule: nil,
            argTypes: ["String"], argLabels: ["forKey"], returnType: "Double",
            isFoundationStateless: false))
        // The scalar setters: `set(_:forKey:)` with a Bool / Int / Double / String
        // first arg. The first arg's type comes from the SYNTAX (a literal / a typed
        // local) — the table confirms the `forKey:String` + the `Void` return. We add
        // one entry per first-arg type so the canonical signature is keyed per overload
        // (the wire tag of arg 0 must match the resolver-thunk's decode).
        for t in ["Bool", "Int", "Double", "String"] {
            e.append(.init(
                receiver: "UserDefaults.standard", method: "set", arity: 2,
                canonicalReceiver: "Foundation.UserDefaults", requiredModule: nil,
                argTypes: [t, "String"], argLabels: [nil, "forKey"], returnType: "Void",
                isFoundationStateless: false))
        }

        // === FileManager (survey #13, 181 hits) — read-only + safe deletes. ======
        // `fileExists(atPath:)->Bool` is the ubiquitous read. `removeItem(atPath:)`
        // is a `throws` mutating op — the engine already registers the WRITE member
        // names `.mustStayNative` for the partitioner; we route ONLY the read here
        // (the survey's "FileManager basics" routable shape), keeping deletes native
        // (a bad OTA delete is data loss). `removeItem` stays OUT.
        e.append(.init(
            receiver: "FileManager.default", method: "fileExists", arity: 1,
            canonicalReceiver: "Foundation.FileManager", requiredModule: nil,
            argTypes: ["String"], argLabels: ["atPath"], returnType: "Bool",
            isFoundationStateless: true))

        // === UIApplication.shared.open (survey #15, 103 hits) — trivial host call. =
        // `open(_:)` (the deprecated-but-linked single-arg form) returns Bool. The
        // `open(_:options:completionHandler:)` form is closure-bearing → EXCLUDED. The
        // URL arg marshals as a String at the boundary; the wire carries the String and
        // the thunk reconstructs `URL(string:)` natively (the BOUNDARY RECONSTRUCTION
        // template below). The canonical receiver carries the UIKit module so the thunk
        // imports it. A non-URL string → `URL(string:)` is nil → the `??` keeps the call
        // honest (it routes to a benign no-op URL rather than crash; a malformed URL was
        // a native no-op anyway).
        e.append(.init(
            receiver: "UIApplication.shared", method: "open", arity: 1,
            canonicalReceiver: "UIKit.UIApplication", requiredModule: "UIKit",
            argTypes: ["String"], argLabels: [nil], returnType: "Bool",
            nativeCallTemplate: "UIApplication.shared.open(URL(string: \u{1}0\u{1}) ?? URL(string: \"about:blank\")!)",
            isFoundationStateless: true))

        return e
    }()

    // -----------------------------------------------------------------------
    // MARK: - Lookup
    // -----------------------------------------------------------------------

    /// The O(1) lookup index, keyed by `<receiver>\u{1}<method>\u{1}<arity>`.
    private static let index: [String: Entry] = {
        var m: [String: Entry] = [:]
        for entry in entries {
            m[key(receiver: entry.receiver, method: entry.method, arity: entry.arity)] = entry
        }
        return m
    }()

    private static func key(receiver: String, method: String, arity: Int) -> String {
        "\(receiver)\u{1}\(method)\u{1}\(arity)"
    }

    /// Look up a confident entry for a call SHAPE (receiver text + method + arity).
    /// Returns `nil` when the symbol is not in the curated table (the syntactic
    /// demote-on-doubt path handles it). A non-`nil` result is a CONFIDENT route the
    /// extractor may use to fill `<unresolved>` types — see `resolve(_:syntacticArgTypes:)`.
    public static func lookup(receiver: String, method: String, arity: Int) -> Entry? {
        index[key(receiver: receiver, method: method, arity: arity)]
    }

    /// The set of first-arg types a `set`-style overloaded setter accepts. Used by the
    /// extractor to pick the matching overload entry when the SYNTAX already typed arg 0
    /// (so `defaults.set(true, forKey: k)` keys the Bool overload, not the Int one).
    public static func overloadEntry(receiver: String, method: String, arity: Int,
                                     firstArgType: String?) -> Entry? {
        // Fast path: a single entry for this (receiver, method, arity).
        if let only = lookup(receiver: receiver, method: method, arity: arity) {
            // If the syntax typed arg 0 AND it disagrees with the single entry's arg-0
            // type, this overload doesn't fit → no confident route (demote-on-doubt).
            if let firstArgType, !firstArgType.isEmpty,
               firstArgType != HostBridgeKnownSymbols.unresolvedMarker,
               !only.argTypes.isEmpty, only.argTypes[0] != firstArgType {
                // Fall through to the multi-overload search below.
            } else {
                return only
            }
        }
        // Multi-overload setters: choose the entry whose arg-0 type matches the syntax.
        guard let firstArgType, !firstArgType.isEmpty,
              firstArgType != HostBridgeKnownSymbols.unresolvedMarker else { return nil }
        return entries.first {
            $0.receiver == receiver && $0.method == method && $0.arity == arity
                && !$0.argTypes.isEmpty && $0.argTypes[0] == firstArgType
        }
    }

    /// The `<unresolved>` sentinel the extractor uses (mirrored here so the table can
    /// reason about it without importing the extractor's constant — kept identical).
    public static let unresolvedMarker = "<unresolved>"

    /// The resolved types a confident entry supplies for a call: the per-arg types
    /// (UPGRADING any `<unresolved>` syntactic type to the curated one, but never
    /// OVERRIDING a conflicting concrete syntactic type) + the return type.
    ///
    /// Returns `nil` (no confident upgrade) when:
    ///   * the entry's arg count doesn't match `syntacticArgTypes` (defensive), OR
    ///   * the syntax already typed an arg to a CONCRETE type that CONFLICTS with the
    ///     entry's (the call doesn't fit the curated overload → demote-on-doubt).
    /// On success, returns the upgraded arg types + the curated return type.
    public static func resolve(_ entry: Entry,
                               syntacticArgTypes: [String]) -> (argTypes: [String], returnType: String)? {
        guard entry.argTypes.count == syntacticArgTypes.count else { return nil }
        var upgraded: [String] = []
        upgraded.reserveCapacity(entry.argTypes.count)
        for (curated, syntactic) in zip(entry.argTypes, syntacticArgTypes) {
            let s = syntactic.trimmingCharacters(in: .whitespaces)
            if s.isEmpty || s == unresolvedMarker {
                // The syntax couldn't type it → adopt the curated fact (the confident
                // upgrade — the WHOLE point of the table).
                upgraded.append(curated)
            } else if s == curated {
                // The syntax agreed → keep it (no change).
                upgraded.append(curated)
            } else {
                // The syntax typed it to a DIFFERENT concrete type → this call does not
                // fit the curated overload (a mis-marshal risk). Refuse to upgrade; the
                // demote-on-doubt path keeps it native.
                return nil
            }
        }
        return (upgraded, entry.returnType)
    }
}
