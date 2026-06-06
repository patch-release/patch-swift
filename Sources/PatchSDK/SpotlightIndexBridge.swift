import Foundation
import WasmKit
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif

// MARK: - SpotlightItem value type
//
// A cross-platform description of one searchable item to index in Spotlight. A
// plain `Sendable` struct (no CoreSpotlight types) so the bridge core compiles +
// unit-tests on macOS; the iOS shell maps it onto a `CSSearchableItem` with a
// `CSSearchableItemAttributeSet` in the `#if canImport(CoreSpotlight)` handler.
public struct SpotlightItem: Sendable, Equatable {
    /// Stable unique identifier for the item (used to update / delete it later).
    public let identifier: String
    /// The displayed title in Spotlight results.
    public let title: String
    /// Optional content description / subtitle.
    public let contentDescription: String?
    /// Optional `domainIdentifier` to group items (so a domain can be purged).
    public let domain: String?
    /// Optional searchable keywords.
    public let keywords: [String]

    public init(
        identifier: String,
        title: String,
        contentDescription: String?,
        domain: String?,
        keywords: [String]
    ) {
        self.identifier = identifier
        self.title = title
        self.contentDescription = contentDescription
        self.domain = domain
        self.keywords = keywords
    }
}

// MARK: - SpotlightIndex bridge (index an item into CoreSpotlight)
//
// spotlight_index(ptr,len) -> i32 — index a searchable item described by JSON;
// 1 if the item was valid and handed to the indexer, 0 if the JSON was invalid
// (missing a non-empty identifier + title).
//
// Lets an OTA patch make app content discoverable from system search without
// linking CoreSpotlight into the wasm. The guest passes an item as JSON; the
// host decodes it into a `SpotlightItem` and hands it to an injected indexer
// (the real iOS shell builds a `CSSearchableItem` and calls
// `CSSearchableIndex.default().indexSearchableItems(...)`).
//
// Item JSON (identifier + title required; others optional):
//   {"identifier":"note-42","title":"Groceries",
//    "description":"Milk, eggs","domain":"notes","keywords":["shopping","todo"]}
//
// ## Cross-platform core + injected dependency (guide Rule 2)
// The indexer is injected as a `@Sendable (_ item: SpotlightItem) -> Void` so the
// struct + its `register(...)` marshalling + the JSON decode compile and
// unit-test on macOS without binding CoreSpotlight at the top level. Tests inject
// a spy recording the decoded item; the convenience `init()` wires the real
// `CSSearchableIndex` under `#if canImport(CoreSpotlight)`. The JSON decode is a
// pure `static func parse(_:)` unit-tested directly.
public struct SpotlightIndexBridge: Bridge {
    /// Index a decoded searchable item. Injected so the bridge is testable.
    public typealias Indexer = @Sendable (_ item: SpotlightItem) -> Void

    public let module = "patch"
    private let index: Indexer

    /// Cross-platform designated init — tests inject a spy indexer.
    public init(index: @escaping Indexer) { self.index = index }

    #if canImport(CoreSpotlight)
    /// Convenience default init: wires the real `CSSearchableIndex.default()`.
    /// Builds a `CSSearchableItem` (with a content attribute set) from the decoded
    /// `SpotlightItem` and submits it. Guarded by `canImport(CoreSpotlight)` so the
    /// cross-platform core compiles on macOS (CoreSpotlight is absent there).
    public init() {
        self.init(index: { item in
            let attrs = CSSearchableItemAttributeSet(contentType: .content)
            attrs.title = item.title
            attrs.contentDescription = item.contentDescription
            if !item.keywords.isEmpty { attrs.keywords = item.keywords }
            let searchable = CSSearchableItem(
                uniqueIdentifier: item.identifier,
                domainIdentifier: item.domain,
                attributeSet: attrs
            )
            CSSearchableIndex.default().indexSearchableItems([searchable]) { _ in }
        })
    }
    #endif

    /// Decode the item JSON into a `SpotlightItem`, or nil if it lacks a non-empty
    /// `identifier` + `title` (an item with no id can't be addressed; one with no
    /// title is useless in results). Optional fields default to nil / empty.
    /// Keywords accept a JSON array of strings (non-strings dropped). Pure +
    /// unit-tested directly.
    public static func parse(_ bytes: [UInt8]) -> SpotlightItem? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
              let identifier = (obj["identifier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !identifier.isEmpty,
              let title = (obj["title"] as? String), !title.isEmpty else {
            return nil
        }
        let description = (obj["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let domain = (obj["domain"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let keywords = (obj["keywords"] as? [Any])?.compactMap { $0 as? String } ?? []
        return SpotlightItem(
            identifier: identifier,
            title: title,
            contentDescription: description,
            domain: domain,
            keywords: keywords
        )
    }

    /// The dispatch the `spotlight_index` host function runs: decode + hand to the
    /// indexer. Returns whether the item was valid (and thus indexed). Exposed
    /// (internally) so the decode→dispatch path is unit-tested without a wasm
    /// fixture exporting `call_spotlight_index`.
    @discardableResult
    func indexPayload(_ bytes: [UInt8]) -> Bool {
        guard let item = Self.parse(bytes) else { return false }
        index(item)
        return true
    }

    public func register(into imports: inout Imports, store: Store) {
        let bridge = self
        imports.host(module, "spotlight_index", [.i32, .i32], [.i32], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let bytes = try ctx.readBytes(ptr: args[0].i32, len: args[1].i32)
            return [.i32(bridge.indexPayload(bytes) ? 1 : 0)]
        }
    }
}
