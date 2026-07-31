// SPDX-License-Identifier: MIT

import Foundation

// ===========================================================================
// THE SYMBOL MANIFEST (DESIGN §2.3 / §5 — the `patch_host_symbols` side table).
//
// The engine emits, alongside a module, a list of the symbols it chose to route
// through the generic bridge: each entry is
//   { id, canonicalSignature, argTags[], retTag }
// where `id` is the stable (content-addressed) symbolId, `canonicalSignature`
// the fully-qualified demangled symbol the build-time resolver-thunk matched,
// and `argTags`/`retTag` the declared TLV tags of the call.
//
// The SDK reads this once per module activation. For PART A its job is narrow:
// VALIDATE ids — i.e. learn which ids the module expects so the runtime can
// answer `have()` and so a registered thunk for an unexpected id can be flagged.
// Full signature → thunk resolution is the build-time resolver-thunk's job (it
// registers a closure per id directly via PatchHostBridge.register); the
// manifest is the cross-check, not the resolution mechanism.
//
// Wire form: a UTF-8 JSON blob the engine emits (Foundation `JSONSerialization`
// on the SDK side — the SDK is full-Foundation; only the GUEST is embedded). We
// parse defensively: a malformed/absent manifest yields an empty descriptor set
// rather than throwing, so a parse problem degrades to "no validated ids"
// (every call then relies on the live registry + the tagged-error demote path),
// never a crash. (Closed-internal-testing posture: no schema-version gate yet.)
// ===========================================================================

/// One symbol the engine routed, as described by the manifest. `argTags`/`retTag`
/// are the raw TLV tag bytes (see `TLVTag`).
public struct HostSymbolDescriptor: Sendable, Equatable {
    public let id: Int32
    public let canonicalSignature: String
    public let argTags: [UInt8]
    public let retTag: UInt8

    public init(id: Int32, canonicalSignature: String, argTags: [UInt8], retTag: UInt8) {
        self.id = id
        self.canonicalSignature = canonicalSignature
        self.argTags = argTags
        self.retTag = retTag
    }
}

/// The parsed `patch_host_symbols` manifest: the set of symbols a module expects
/// the host to resolve.
public struct HostSymbolManifest: Sendable {
    public let symbols: [HostSymbolDescriptor]

    public init(symbols: [HostSymbolDescriptor]) { self.symbols = symbols }

    /// The empty manifest (no validated ids — the degraded-but-safe default).
    public static let empty = HostSymbolManifest(symbols: [])

    /// Ids the module declares it routes.
    public var declaredIDs: Set<Int32> { Set(symbols.map(\.id)) }

    public func descriptor(for id: Int32) -> HostSymbolDescriptor? {
        symbols.first { $0.id == id }
    }

    /// Parse a `patch_host_symbols` JSON blob. Defensive: returns `.empty` on any
    /// malformed/unparseable input (the runtime then leans on the live registry +
    /// tagged-error demote path). Accepts either a top-level array of entries, or
    /// an object `{ "symbols": [ … ] }` (the engine may wrap it).
    ///
    /// Each entry: `{ "id": <int>, "sig": <string>, "args": [<int>…], "ret": <int> }`.
    /// `sig`/`canonicalSignature`, `args`/`argTags`, `ret`/`retTag` aliases are
    /// all accepted so the engine side has latitude on key names.
    public static func parse(_ bytes: [UInt8]) -> HostSymbolManifest {
        guard !bytes.isEmpty,
              let top = try? JSONSerialization.jsonObject(with: Data(bytes), options: [])
        else { return .empty }

        let rawEntries: [Any]
        if let arr = top as? [Any] {
            rawEntries = arr
        } else if let obj = top as? [String: Any], let arr = obj["symbols"] as? [Any] {
            rawEntries = arr
        } else {
            return .empty
        }

        var out: [HostSymbolDescriptor] = []
        for case let e as [String: Any] in rawEntries {
            guard let idNum = (e["id"] as? NSNumber)?.int32Value else { continue }
            let sig = (e["sig"] as? String) ?? (e["canonicalSignature"] as? String) ?? ""
            let argArr = (e["args"] as? [Any]) ?? (e["argTags"] as? [Any]) ?? []
            let argTags = argArr.compactMap { ($0 as? NSNumber)?.uint8Value }
            let retTag = (e["ret"] as? NSNumber)?.uint8Value
                       ?? (e["retTag"] as? NSNumber)?.uint8Value
                       ?? TLVTag.nilValue.rawValue
            out.append(HostSymbolDescriptor(id: idNum, canonicalSignature: sig,
                                            argTags: argTags, retTag: retTag))
        }
        return HostSymbolManifest(symbols: out)
    }

    /// Convenience: parse from a UTF-8 string.
    public static func parse(_ json: String) -> HostSymbolManifest {
        parse([UInt8](json.utf8))
    }
}
