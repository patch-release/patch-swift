import XCTest
import WasmKit
@testable import PatchSDK

/// Analytics (event tracking) bridge tests. The prebuilt `BridgeFixture.wasm`
/// does NOT export `call_analytics_track` / `call_analytics_screen`, so per the
/// bridge guide we test the bridge's pure logic + dispatch directly:
///   1. `AnalyticsBridge.parseTrack` — JSON → (event, props) string coercion
///      (valid, missing event, nested props), tested as a pure static func.
///   2. The injected `AnalyticsSink` spy receives the right (event, props) /
///      screen name when the bridge's parse-then-dispatch path runs.
final class AnalyticsBridgeTests: XCTestCase {

    // MARK: - parseTrack (pure logic)

    /// Valid payload: event + flat props, all coerced to strings.
    func testParseTrackValid() throws {
        let json = Array(#"{"event":"checkout_completed","props":{"amount":42,"currency":"USD"}}"#.utf8)
        let parsed = try XCTUnwrap(AnalyticsBridge.parseTrack(json))
        XCTAssertEqual(parsed.event, "checkout_completed")
        XCTAssertEqual(parsed.props, ["amount": "42", "currency": "USD"])
    }

    /// Numbers and bools coerce to their textual form; strings pass through.
    func testParseTrackCoercesScalarTypes() throws {
        let json = Array(#"{"event":"e","props":{"int":7,"float":3.5,"flag":true,"off":false,"name":"Ada"}}"#.utf8)
        let parsed = try XCTUnwrap(AnalyticsBridge.parseTrack(json))
        XCTAssertEqual(parsed.props["int"], "7")            // integer, no ".0"
        XCTAssertEqual(parsed.props["float"], "3.5")        // float keeps decimals
        XCTAssertEqual(parsed.props["flag"], "true")        // bool, NOT "1"
        XCTAssertEqual(parsed.props["off"], "false")
        XCTAssertEqual(parsed.props["name"], "Ada")
    }

    /// Missing event → nil (the whole payload is rejected).
    func testParseTrackMissingEvent() {
        XCTAssertNil(AnalyticsBridge.parseTrack(Array(#"{"props":{"a":1}}"#.utf8)))
    }

    /// Empty-string event is treated as missing → nil.
    func testParseTrackEmptyEvent() {
        XCTAssertNil(AnalyticsBridge.parseTrack(Array(#"{"event":"","props":{"a":1}}"#.utf8)))
    }

    /// Non-string event (wrong type) → nil.
    func testParseTrackNonStringEvent() {
        XCTAssertNil(AnalyticsBridge.parseTrack(Array(#"{"event":123}"#.utf8)))
    }

    /// Event with no props → empty props dictionary (still a valid track).
    func testParseTrackNoProps() throws {
        let parsed = try XCTUnwrap(AnalyticsBridge.parseTrack(Array(#"{"event":"screen_view"}"#.utf8)))
        XCTAssertEqual(parsed.event, "screen_view")
        XCTAssertTrue(parsed.props.isEmpty)
    }

    /// Nested objects / arrays / null inside props are dropped (flat scalars only);
    /// sibling flat scalars survive.
    func testParseTrackDropsNestedProps() throws {
        let json = Array(#"{"event":"e","props":{"nested":{"k":"v"},"list":[1,2],"nil":null,"keep":"yes"}}"#.utf8)
        let parsed = try XCTUnwrap(AnalyticsBridge.parseTrack(json))
        XCTAssertEqual(parsed.props, ["keep": "yes"], "nested object/array/null props must be dropped")
    }

    /// Non-object / malformed JSON → nil.
    func testParseTrackNonObject() {
        XCTAssertNil(AnalyticsBridge.parseTrack(Array("not json at all {".utf8)))
        XCTAssertNil(AnalyticsBridge.parseTrack(Array(#"[1,2,3]"#.utf8)))   // top-level array
    }

    // MARK: - Dispatch to an injected spy sink

    /// The bridge parses the JSON and dispatches (event, props) to the injected
    /// sink. Drives the same parse-then-dispatch path the registered host
    /// function runs, with a spy in place of a real analytics SDK.
    func testTrackDispatchesToSink() {
        let spy = SpySink()
        let bridge = AnalyticsBridge(sink: spy)

        let json = Array(#"{"event":"purchase","props":{"sku":"ABC","qty":2}}"#.utf8)
        if let parsed = AnalyticsBridge.parseTrack(json) {
            // Mirror exactly what register(...) does on the host side.
            bridge.dispatchTrack(parsed)
        }

        XCTAssertEqual(spy.tracked.count, 1)
        XCTAssertEqual(spy.tracked.first?.event, "purchase")
        XCTAssertEqual(spy.tracked.first?.props, ["sku": "ABC", "qty": "2"])
        XCTAssertTrue(spy.screens.isEmpty)
    }

    /// A screen call forwards the raw name string to the sink.
    func testScreenDispatchesToSink() {
        let spy = SpySink()
        AnalyticsBridge(sink: spy).dispatchScreen("home")
        XCTAssertEqual(spy.screens, ["home"])
        XCTAssertTrue(spy.tracked.isEmpty)
    }

    /// The default (no-arg) init is usable out of the box — wires the logging
    /// sink and constructs without error. (Cross-platform: no real SDK needed.)
    func testDefaultInitUsableOutOfBox() {
        XCTAssertNoThrow(AnalyticsBridge())
        // And it registers host imports without error under the default registry.
        let registry = BridgeRegistry()
        registry.register(AnalyticsBridge())
        XCTAssertNotNil(registry.hostImports())
    }
}

/// Spy `AnalyticsSink` that records every dispatched call for assertions.
private final class SpySink: AnalyticsSink, @unchecked Sendable {
    struct Event: Sendable { let event: String; let props: [String: String] }
    private let lock = NSLock()
    private var _tracked: [Event] = []
    private var _screens: [String] = []

    func track(event: String, props: [String: String]) {
        lock.lock(); _tracked.append(.init(event: event, props: props)); lock.unlock()
    }
    func screen(_ name: String) {
        lock.lock(); _screens.append(name); lock.unlock()
    }

    var tracked: [Event] { lock.lock(); defer { lock.unlock() }; return _tracked }
    var screens: [String] { lock.lock(); defer { lock.unlock() }; return _screens }
}
