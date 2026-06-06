import XCTest
import WasmKit
@testable import PatchSDK

/// SpotlightIndexBridge — `patch.spotlight_index(json) -> i32`. The CoreSpotlight
/// indexer is injected as a `@Sendable (SpotlightItem) -> Void`, so tests inject a
/// spy that records the decoded item. Two layers:
///   1. `parse(_:)` — item JSON → SpotlightItem (or nil), tested directly.
///   2. `indexPayload(_:)` — the decode→dispatch path the host fn runs, with a spy.
/// No real CoreSpotlight / wasm fixture required.
final class SpotlightIndexBridgeTests: XCTestCase {

    private typealias Bridge = SpotlightIndexBridge

    // MARK: - parse

    func testParseFullItem() throws {
        let json = #"{"identifier":"note-42","title":"Groceries","description":"Milk, eggs","domain":"notes","keywords":["shopping","todo"]}"#
        let item = try XCTUnwrap(Bridge.parse(Array(json.utf8)))
        XCTAssertEqual(item.identifier, "note-42")
        XCTAssertEqual(item.title, "Groceries")
        XCTAssertEqual(item.contentDescription, "Milk, eggs")
        XCTAssertEqual(item.domain, "notes")
        XCTAssertEqual(item.keywords, ["shopping", "todo"])
    }

    func testParseMinimalItem() throws {
        let item = try XCTUnwrap(Bridge.parse(Array(#"{"identifier":"x","title":"Hello"}"#.utf8)))
        XCTAssertEqual(item.identifier, "x")
        XCTAssertEqual(item.title, "Hello")
        XCTAssertNil(item.contentDescription)
        XCTAssertNil(item.domain)
        XCTAssertTrue(item.keywords.isEmpty)
    }

    func testParseTrimsIdentifier() throws {
        let item = try XCTUnwrap(Bridge.parse(Array(#"{"identifier":"  id-1  ","title":"T"}"#.utf8)))
        XCTAssertEqual(item.identifier, "id-1")
    }

    func testParseDropsNonStringKeywords() throws {
        let item = try XCTUnwrap(Bridge.parse(Array(#"{"identifier":"x","title":"T","keywords":["a",1,true,"b"]}"#.utf8)))
        XCTAssertEqual(item.keywords, ["a", "b"], "non-string keywords dropped")
    }

    func testParseEmptyOptionalsBecomeNil() throws {
        let item = try XCTUnwrap(Bridge.parse(Array(#"{"identifier":"x","title":"T","description":"","domain":""}"#.utf8)))
        XCTAssertNil(item.contentDescription, "empty description → nil")
        XCTAssertNil(item.domain, "empty domain → nil")
    }

    func testParseRejectsMissingRequiredFields() {
        XCTAssertNil(Bridge.parse(Array(#"{"title":"no id"}"#.utf8)), "missing identifier")
        XCTAssertNil(Bridge.parse(Array(#"{"identifier":"x"}"#.utf8)), "missing title")
        XCTAssertNil(Bridge.parse(Array(#"{"identifier":"","title":"T"}"#.utf8)), "blank identifier")
        XCTAssertNil(Bridge.parse(Array(#"{"identifier":"  ","title":"T"}"#.utf8)), "whitespace identifier")
        XCTAssertNil(Bridge.parse(Array(#"{"identifier":"x","title":""}"#.utf8)), "empty title")
        XCTAssertNil(Bridge.parse(Array("not json".utf8)))
        XCTAssertNil(Bridge.parse(Array(#"[1,2,3]"#.utf8)), "top-level array")
    }

    // MARK: - Dispatch through a spy indexer

    private final class IndexSpy: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var items: [SpotlightItem] = []
        var index: Bridge.Indexer {
            { [self] item in lock.lock(); items.append(item); lock.unlock() }
        }
    }

    /// A valid item is decoded and handed to the indexer; the host fn returns 1.
    func testIndexPayloadDispatchesValidItem() {
        let spy = IndexSpy()
        let bridge = Bridge(index: spy.index)
        let json = #"{"identifier":"note-1","title":"Title","keywords":["k"]}"#
        XCTAssertTrue(bridge.indexPayload(Array(json.utf8)))
        XCTAssertEqual(spy.items.count, 1)
        XCTAssertEqual(spy.items.first?.identifier, "note-1")
        XCTAssertEqual(spy.items.first?.keywords, ["k"])
    }

    /// An invalid item returns false WITHOUT consulting the indexer.
    func testIndexPayloadInvalidSkipsIndexer() {
        let spy = IndexSpy()
        let bridge = Bridge(index: spy.index)
        XCTAssertFalse(bridge.indexPayload(Array(#"{"title":"no id"}"#.utf8)))
        XCTAssertFalse(bridge.indexPayload(Array("garbage".utf8)))
        XCTAssertTrue(spy.items.isEmpty, "invalid items must not reach the indexer")
    }

    // MARK: - Bridge shape / registration

    func testModuleNamespaceAndRegistration() {
        let bridge = Bridge(index: { _ in })
        XCTAssertEqual(bridge.module, "patch")
        XCTAssertNotNil(BridgeRegistry().register(bridge).hostImports())
    }

    #if canImport(CoreSpotlight)
    func testDefaultInitRegisters() {
        XCTAssertNotNil(BridgeRegistry().register(SpotlightIndexBridge()).hostImports())
    }
    #endif
}
