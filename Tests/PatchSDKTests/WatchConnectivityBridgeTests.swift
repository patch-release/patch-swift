import XCTest
import WasmKit
@testable import PatchSDK

/// WatchConnectivityBridge — host bridge for sending a message dict to the watch.
///
/// Two layers under test:
///   1. `parse(_:)` — the pure JSON-object→`[String:String]` decode (string
///      values only; non-string values + non-object JSON → empty).
///   2. Dispatch of `send_watch_message(ptr,len)` through a hand-built wasm module
///      (imports `patch.send_watch_message`, exports `call_f(i32,i32)` plus
///      memory/malloc/free). A spy stands in for WCSession.
final class WatchConnectivityBridgeTests: XCTestCase {

    private static let fixture: [UInt8] = [
        0, 97, 115, 109, 1, 0, 0, 0, 1, 15, 3, 96, 2, 127, 127, 0, 96, 1, 127, 1, 127,
        96, 1, 127, 0, 2, 28, 1, 5, 112, 97, 116, 99, 104, 18, 115, 101, 110,
        100, 95, 119, 97, 116, 99, 104, 95, 109, 101, 115, 115, 97, 103, 101,
        0, 0, 3, 4, 3, 1, 2, 0, 5, 3, 1, 0, 1, 6, 7, 1, 127, 1, 65, 128, 8,
        11, 7, 47, 4, 6, 109, 101, 109, 111, 114, 121, 2, 0, 12, 112, 97, 116,
        99, 104, 95, 109, 97, 108, 108, 111, 99, 0, 1, 10, 112, 97, 116, 99,
        104, 95, 102, 114, 101, 101, 0, 2, 6, 99, 97, 108, 108, 95, 102, 0, 3,
        10, 37, 3, 23, 1, 1, 127, 35, 0, 33, 1, 35, 0, 32, 0, 106, 65, 7, 106,
        65, 120, 113, 36, 0, 32, 1, 11, 2, 0, 11, 8, 0, 32, 0, 32, 1, 16, 0,
        11,
    ]

    // MARK: - parse(_:) pure decode

    func testParseStringPairs() {
        let msg = WatchConnectivityBridge.parse(Array(#"{"action":"refresh","id":"42"}"#.utf8))
        XCTAssertEqual(msg, ["action": "refresh", "id": "42"])
    }

    func testParseDropsNonStringValues() {
        let msg = WatchConnectivityBridge.parse(Array(#"""
        {"keep":"yes","num":5,"flag":true,"obj":{"x":1},"arr":[1,2]}
        """#.utf8))
        XCTAssertEqual(msg, ["keep": "yes"])
    }

    func testParseInvalidOrNonObjectYieldsEmpty() {
        XCTAssertTrue(WatchConnectivityBridge.parse(Array("not json".utf8)).isEmpty)
        XCTAssertTrue(WatchConnectivityBridge.parse(Array("[1,2,3]".utf8)).isEmpty)
        XCTAssertTrue(WatchConnectivityBridge.parse(Array("{}".utf8)).isEmpty)
        XCTAssertTrue(WatchConnectivityBridge.parse([]).isEmpty)
    }

    func testParsePreservesUnicode() {
        let msg = WatchConnectivityBridge.parse(Array(#"{"t":"níce 🎉"}"#.utf8))
        XCTAssertEqual(msg, ["t": "níce 🎉"])
    }

    // MARK: - Dispatch through the wasm fixture

    func testDispatchDecodesAndInvokes() throws {
        let spy = WatchSpy()
        let rt = try WASMRuntime(
            bytes: Self.fixture,
            hostImports: BridgeRegistry().register(WatchConnectivityBridge(send: spy.send)).hostImports())

        let (ptr, len) = try rt.writeBuffer([UInt8](#"{"cmd":"start","arg":"now"}"#.utf8))
        _ = try rt.invoke("call_f", [.i32(ptr), .i32(len)])

        XCTAssertEqual(spy.messages.count, 1)
        XCTAssertEqual(spy.messages.first, ["cmd": "start", "arg": "now"])
    }

    func testDispatchInvalidJSONStillFiresWithEmpty() throws {
        let spy = WatchSpy()
        let rt = try WASMRuntime(
            bytes: Self.fixture,
            hostImports: BridgeRegistry().register(WatchConnectivityBridge(send: spy.send)).hostImports())

        let (ptr, len) = try rt.writeBuffer([UInt8]("garbage".utf8))
        _ = try rt.invoke("call_f", [.i32(ptr), .i32(len)])

        XCTAssertEqual(spy.messages.count, 1)
        XCTAssertEqual(spy.messages.first, [:], "fire-and-forget: invalid input sends an empty dict")
    }

    #if canImport(WatchConnectivity)
    func testDefaultInitRegistersOnWatchConnectivity() throws {
        let registry = BridgeRegistry().register(WatchConnectivityBridge())
        XCTAssertNoThrow(try WASMRuntime(bytes: Self.fixture, hostImports: registry.hostImports()))
    }
    #endif
}

private final class WatchSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _messages: [[String: String]] = []
    var send: WatchConnectivityBridge.Sender {
        { [self] msg in lock.lock(); _messages.append(msg); lock.unlock() }
    }
    var messages: [[String: String]] { lock.lock(); defer { lock.unlock() }; return _messages }
}
