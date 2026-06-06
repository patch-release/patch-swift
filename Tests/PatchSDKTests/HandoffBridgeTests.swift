import XCTest
import WasmKit
@testable import PatchSDK

/// HandoffBridge — host bridge for start/stop of an NSUserActivity (Handoff).
///
/// Two layers under test:
///   1. `parse(_:)` — the pure JSON→`HandoffActivity?` decode (required
///      `activityType`, optional title/webpageURL/userInfo, eligible default,
///      invalid JSON → nil).
///   2. Dispatch of `start_handoff(ptr,len)` / `stop_handoff(ptr,len)` through a
///      hand-built wasm module (imports both, exports `call_start` / `call_stop`
///      plus memory/malloc/free). Spies stand in for NSUserActivity.
final class HandoffBridgeTests: XCTestCase {

    private static let fixture: [UInt8] = [
        0, 97, 115, 109, 1, 0, 0, 0, 1, 15, 3, 96, 2, 127, 127, 0, 96, 1, 127, 1, 127,
        96, 1, 127, 0, 2, 44, 2, 5, 112, 97, 116, 99, 104, 13, 115, 116, 97,
        114, 116, 95, 104, 97, 110, 100, 111, 102, 102, 0, 0, 5, 112, 97, 116,
        99, 104, 12, 115, 116, 111, 112, 95, 104, 97, 110, 100, 111, 102, 102,
        0, 0, 3, 5, 4, 1, 2, 0, 0, 5, 3, 1, 0, 1, 6, 7, 1, 127, 1, 65, 128, 8,
        11, 7, 63, 5, 6, 109, 101, 109, 111, 114, 121, 2, 0, 12, 112, 97, 116,
        99, 104, 95, 109, 97, 108, 108, 111, 99, 0, 2, 10, 112, 97, 116, 99,
        104, 95, 102, 114, 101, 101, 0, 3, 10, 99, 97, 108, 108, 95, 115, 116,
        97, 114, 116, 0, 4, 9, 99, 97, 108, 108, 95, 115, 116, 111, 112, 0, 5,
        10, 46, 4, 23, 1, 1, 127, 35, 0, 33, 1, 35, 0, 32, 0, 106, 65, 7, 106,
        65, 120, 113, 36, 0, 32, 1, 11, 2, 0, 11, 8, 0, 32, 0, 32, 1, 16, 0,
        11, 8, 0, 32, 0, 32, 1, 16, 1, 11,
    ]

    private func makeRuntime(_ bridge: HandoffBridge) throws -> WASMRuntime {
        try WASMRuntime(bytes: Self.fixture,
                        hostImports: BridgeRegistry().register(bridge).hostImports())
    }

    // MARK: - parse(_:) pure decode

    func testParseFullActivity() {
        let a = HandoffBridge.parse(Array(#"""
        {"activityType":"com.acme.read","title":"Reading","webpageURL":"https://acme.com/p/1",
         "userInfo":{"id":"1"},"eligibleForHandoff":false}
        """#.utf8))
        let activity = a!
        XCTAssertEqual(activity.activityType, "com.acme.read")
        XCTAssertEqual(activity.title, "Reading")
        XCTAssertEqual(activity.webpageURL, "https://acme.com/p/1")
        XCTAssertEqual(activity.userInfo, ["id": "1"])
        XCTAssertFalse(activity.eligibleForHandoff)
    }

    func testParseMinimalDefaults() {
        let activity = HandoffBridge.parse(Array(#"{"activityType":"a.b"}"#.utf8))!
        XCTAssertEqual(activity.activityType, "a.b")
        XCTAssertNil(activity.title)
        XCTAssertNil(activity.webpageURL)
        XCTAssertTrue(activity.userInfo.isEmpty)
        XCTAssertTrue(activity.eligibleForHandoff, "eligibleForHandoff defaults to true")
    }

    func testParseRejectsMissingOrEmptyType() {
        XCTAssertNil(HandoffBridge.parse(Array(#"{"title":"no type"}"#.utf8)))
        XCTAssertNil(HandoffBridge.parse(Array(#"{"activityType":""}"#.utf8)))
        XCTAssertNil(HandoffBridge.parse(Array("not json".utf8)))
        XCTAssertNil(HandoffBridge.parse(Array(#"["array"]"#.utf8)))
        XCTAssertNil(HandoffBridge.parse([]))
    }

    func testParseUserInfoDropsNonStrings() {
        let activity = HandoffBridge.parse(Array(#"""
        {"activityType":"t","userInfo":{"keep":"x","n":1}}
        """#.utf8))!
        XCTAssertEqual(activity.userInfo, ["keep": "x"])
    }

    // MARK: - Dispatch through the wasm fixture

    func testStartDispatchDecodesAndInvokes() throws {
        let spy = HandoffSpy()
        let rt = try makeRuntime(HandoffBridge(start: spy.start, stop: spy.stop))

        let json = #"{"activityType":"com.acme.task","title":"Task"}"#
        let (ptr, len) = try rt.writeBuffer([UInt8](json.utf8))
        _ = try rt.invoke("call_start", [.i32(ptr), .i32(len)])

        XCTAssertEqual(spy.started.count, 1)
        XCTAssertEqual(spy.started.first?.activityType, "com.acme.task")
        XCTAssertEqual(spy.started.first?.title, "Task")
    }

    func testStartDispatchInvalidJSONIsNoOp() throws {
        let spy = HandoffSpy()
        let rt = try makeRuntime(HandoffBridge(start: spy.start, stop: spy.stop))

        let (ptr, len) = try rt.writeBuffer([UInt8]("garbage".utf8))
        _ = try rt.invoke("call_start", [.i32(ptr), .i32(len)])

        XCTAssertEqual(spy.started.count, 0, "invalid payload → start is not called")
    }

    func testStopDispatchForwardsType() throws {
        let spy = HandoffSpy()
        let rt = try makeRuntime(HandoffBridge(start: spy.start, stop: spy.stop))

        let (ptr, len) = try rt.writeBuffer([UInt8]("com.acme.task".utf8))
        _ = try rt.invoke("call_stop", [.i32(ptr), .i32(len)])

        XCTAssertEqual(spy.stopped, ["com.acme.task"])
    }

    #if canImport(Foundation)
    func testDefaultInitRegisters() throws {
        let registry = BridgeRegistry().register(HandoffBridge())
        XCTAssertNoThrow(try WASMRuntime(bytes: Self.fixture, hostImports: registry.hostImports()))
    }
    #endif
}

private final class HandoffSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _started: [HandoffActivity] = []
    private var _stopped: [String] = []
    var start: HandoffBridge.Start {
        { [self] a in lock.lock(); _started.append(a); lock.unlock() }
    }
    var stop: HandoffBridge.Stop {
        { [self] t in lock.lock(); _stopped.append(t); lock.unlock() }
    }
    var started: [HandoffActivity] { lock.lock(); defer { lock.unlock() }; return _started }
    var stopped: [String] { lock.lock(); defer { lock.unlock() }; return _stopped }
}
