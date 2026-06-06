import XCTest
import WasmKit
@testable import PatchSDK

/// Tests for `CalendarBridge` (EventKit event creation).
///
/// Per the bridge-implementation guide we do NOT rely on the prebuilt
/// `BridgeFixture.wasm` (it does not export `call_calendar_add_event`). We test
/// the bridge two ways:
///   1. `CalendarBridge.parse` — JSON → `CalendarEvent`, as a pure static func
///      (valid / missing-title / missing-times / notes-optional / non-object).
///   2. A REAL guest -> host round-trip over a tiny hand-written inline WASM
///      fixture (base64 below) that imports `patch.calendar_add_event` and
///      exports `call_calendar_add_event`: the guest forwards the JSON `(ptr,len)`
///      from linear memory, the host parses it, invokes the injected spy
///      (returning true/false), and encodes the i32 result back. EventKit itself
///      is iOS/macOS-permission-gated and never touched — the native capability
///      is injected as a spy closure.
final class CalendarBridgeTests: XCTestCase {

    // MARK: - parse (pure logic)

    /// Valid payload with all fields, including optional notes.
    func testParseValid() throws {
        let json = Array(#"{"title":"Dentist","startUnix":1700000000,"endUnix":1700003600,"notes":"bring forms"}"#.utf8)
        let event = try XCTUnwrap(CalendarBridge.parse(json))
        XCTAssertEqual(event.title, "Dentist")
        XCTAssertEqual(event.startUnix, 1_700_000_000)
        XCTAssertEqual(event.endUnix, 1_700_003_600)
        XCTAssertEqual(event.notes, "bring forms")
    }

    /// Notes is optional — a payload without it parses with notes == nil.
    func testParseNotesOptional() throws {
        let json = Array(#"{"title":"Standup","startUnix":100,"endUnix":200}"#.utf8)
        let event = try XCTUnwrap(CalendarBridge.parse(json))
        XCTAssertEqual(event.title, "Standup")
        XCTAssertEqual(event.startUnix, 100)
        XCTAssertEqual(event.endUnix, 200)
        XCTAssertNil(event.notes)
    }

    /// A non-String notes value is ignored (treated as absent), event still parses.
    func testParseNonStringNotesIgnored() throws {
        let json = Array(#"{"title":"X","startUnix":1,"endUnix":2,"notes":42}"#.utf8)
        let event = try XCTUnwrap(CalendarBridge.parse(json))
        XCTAssertNil(event.notes)
    }

    /// Missing title → nil (the whole payload is rejected).
    func testParseMissingTitle() {
        XCTAssertNil(CalendarBridge.parse(Array(#"{"startUnix":1,"endUnix":2}"#.utf8)))
    }

    /// Empty-string title is treated as missing → nil.
    func testParseEmptyTitle() {
        XCTAssertNil(CalendarBridge.parse(Array(#"{"title":"","startUnix":1,"endUnix":2}"#.utf8)))
    }

    /// Non-string title (wrong type) → nil.
    func testParseNonStringTitle() {
        XCTAssertNil(CalendarBridge.parse(Array(#"{"title":123,"startUnix":1,"endUnix":2}"#.utf8)))
    }

    /// Missing startUnix → nil.
    func testParseMissingStart() {
        XCTAssertNil(CalendarBridge.parse(Array(#"{"title":"X","endUnix":2}"#.utf8)))
    }

    /// Missing endUnix → nil.
    func testParseMissingEnd() {
        XCTAssertNil(CalendarBridge.parse(Array(#"{"title":"X","startUnix":1}"#.utf8)))
    }

    /// Both times missing → nil.
    func testParseMissingTimes() {
        XCTAssertNil(CalendarBridge.parse(Array(#"{"title":"X"}"#.utf8)))
    }

    /// Non-numeric times (string instead of number) → nil.
    func testParseNonNumericTimes() {
        XCTAssertNil(CalendarBridge.parse(Array(#"{"title":"X","startUnix":"soon","endUnix":"later"}"#.utf8)))
    }

    /// Non-object / malformed JSON → nil.
    func testParseNonObject() {
        XCTAssertNil(CalendarBridge.parse(Array("not json at all {".utf8)))
        XCTAssertNil(CalendarBridge.parse(Array(#"[1,2,3]"#.utf8)))   // top-level array
    }

    // MARK: - Dispatch to an injected spy (no wasm)

    /// The bridge forwards a parsed event to the injected closure and returns its
    /// Bool result. Drives the same parse-then-dispatch path the host runs.
    func testDispatchForwardsParsedEventAndReturnsTrue() {
        let spy = EventBox()
        let bridge = CalendarBridge(addEvent: { ev in spy.set(ev); return true })

        let json = Array(#"{"title":"Lunch","startUnix":5,"endUnix":10,"notes":"with Ada"}"#.utf8)
        let parsed = CalendarBridge.parse(json)!
        let ok = bridge.dispatch(parsed)

        XCTAssertTrue(ok)
        XCTAssertEqual(spy.get(),
                       CalendarEvent(title: "Lunch", startUnix: 5, endUnix: 10, notes: "with Ada"))
    }

    /// A spy returning false propagates as a failed dispatch.
    func testDispatchReturnsFalse() {
        let bridge = CalendarBridge(addEvent: { _ in false })
        let parsed = CalendarBridge.parse(Array(#"{"title":"X","startUnix":1,"endUnix":2}"#.utf8))!
        XCTAssertFalse(bridge.dispatch(parsed))
    }

    // MARK: - Inline fixture (real guest -> host round-trip)

    /// `CalendarFixture.wasm` (181 bytes), built from a hand-written `.wat`:
    ///   (import "patch" "calendar_add_event" (func (param i32 i32) (result i32)))
    ///   exports: memory, patch_malloc, patch_free, call_calendar_add_event
    private static let fixtureBase64 = """
    AGFzbQEAAAABEANgAn9/AX9gAX8Bf2ABfwACHAEFcGF0Y2gSY2FsZW5kYXJfYWRkX2V2ZW50AAAD\
    BAMBAgAFAwEAAQYHAX8BQYAICwdABAZtZW1vcnkCAAxwYXRjaF9tYWxsb2MAAQpwYXRjaF9mcmVl\
    AAIXY2FsbF9jYWxlbmRhcl9hZGRfZXZlbnQAAwolAxcBAX8jACEBIwAgAGpBB2pBeHEkACABCwIA\
    CwgAIAAgARAACw==
    """

    private func fixtureBytes() throws -> [UInt8] {
        let data = try XCTUnwrap(Data(base64Encoded: Self.fixtureBase64,
                                      options: .ignoreUnknownCharacters))
        return [UInt8](data)
    }

    private func makeRuntime(_ bridge: CalendarBridge) throws -> WASMRuntime {
        let registry = BridgeRegistry()
        registry.register(bridge)
        return try WASMRuntime(bytes: try fixtureBytes(), hostImports: registry.hostImports())
    }

    /// Valid JSON round-trips: host decodes (ptr,len), parses, the spy returns
    /// true → guest sees i32 == 1, and the spy receives the exact event.
    func testRoundTripSuccessReturnsOne() throws {
        let spy = EventBox()
        let rt = try makeRuntime(CalendarBridge(addEvent: { ev in spy.set(ev); return true }))

        let json = #"{"title":"Dentist","startUnix":1700000000,"endUnix":1700003600,"notes":"bring forms"}"#
        let (p, l) = try rt.writeBuffer([UInt8](json.utf8))
        let res = try rt.invoke("call_calendar_add_event", [.i32(p), .i32(l)])

        XCTAssertEqual(Int32(bitPattern: res[0].i32), 1, "success encodes as 1")
        XCTAssertEqual(spy.get(),
                       CalendarEvent(title: "Dentist",
                                     startUnix: 1_700_000_000,
                                     endUnix: 1_700_003_600,
                                     notes: "bring forms"),
                       "the event must be decoded from guest memory and passed through")
    }

    /// The injected closure returning false encodes as i32 == 0.
    func testRoundTripFailureReturnsZero() throws {
        let spy = EventBox()
        let rt = try makeRuntime(CalendarBridge(addEvent: { ev in spy.set(ev); return false }))

        let json = #"{"title":"Standup","startUnix":100,"endUnix":200}"#
        let (p, l) = try rt.writeBuffer([UInt8](json.utf8))
        let res = try rt.invoke("call_calendar_add_event", [.i32(p), .i32(l)])

        XCTAssertEqual(Int32(bitPattern: res[0].i32), 0, "failure encodes as 0")
        XCTAssertEqual(spy.get()?.title, "Standup")
        XCTAssertNil(spy.get()?.notes)
    }

    /// A parse failure (missing title) returns 0 WITHOUT invoking the closure.
    func testRoundTripParseFailureReturnsZeroWithoutDispatch() throws {
        let invoked = FlagBox()
        let rt = try makeRuntime(CalendarBridge(addEvent: { _ in invoked.set(); return true }))

        let json = #"{"startUnix":1,"endUnix":2}"#   // no title
        let (p, l) = try rt.writeBuffer([UInt8](json.utf8))
        let res = try rt.invoke("call_calendar_add_event", [.i32(p), .i32(l)])

        XCTAssertEqual(Int32(bitPattern: res[0].i32), 0, "unparseable payload encodes as 0")
        XCTAssertFalse(invoked.get(), "the native closure must NOT run when parsing fails")
    }

    // MARK: - Registry composition

    /// The bridge installs cleanly alongside the default set (no name clashes;
    /// module namespace is "patch").
    func testRegistersWithoutError() throws {
        let registry = BridgeRegistry().registerDefaults()
        registry.register(CalendarBridge(addEvent: { _ in true }))
        XCTAssertNoThrow(try WASMRuntime(bytes: try fixtureBytes(),
                                         hostImports: registry.hostImports()))
    }
}

/// Thread-safe box capturing the event handed to the addEvent spy.
private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CalendarEvent?
    func set(_ v: CalendarEvent) { lock.lock(); value = v; lock.unlock() }
    func get() -> CalendarEvent? { lock.lock(); defer { lock.unlock() }; return value }
}

/// Thread-safe one-shot flag recording whether the spy closure ran.
private final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}
