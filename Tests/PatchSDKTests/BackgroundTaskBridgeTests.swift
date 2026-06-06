import XCTest
import WasmKit
@testable import PatchSDK

/// BackgroundTaskBridge — host bridge for begin/end of a background task.
///
/// Driven end-to-end through WasmKit with a tiny hand-built module (imports
/// `patch.begin_background_task(i32,i32)->i32` / `patch.end_background_task(i32)`,
/// exports `call_begin(i32,i32)->i32` / `call_end(i32)` plus
/// `memory`/`patch_malloc`/`patch_free`). Spies stand in for UIApplication, so the
/// test runs on macOS. We assert the begin decodes the task name + returns the
/// token, and that end forwards the token.
final class BackgroundTaskBridgeTests: XCTestCase {

    // Hand-written wasm (wat2wasm). See BackgroundTaskBridge for the host ABI.
    private static let fixture: [UInt8] = [
        0, 97, 115, 109, 1, 0, 0, 0, 1, 16, 3, 96, 2, 127, 127, 1, 127, 96, 1, 127, 0,
        96, 1, 127, 1, 127, 2, 59, 2, 5, 112, 97, 116, 99, 104, 21, 98, 101,
        103, 105, 110, 95, 98, 97, 99, 107, 103, 114, 111, 117, 110, 100, 95,
        116, 97, 115, 107, 0, 0, 5, 112, 97, 116, 99, 104, 19, 101, 110, 100,
        95, 98, 97, 99, 107, 103, 114, 111, 117, 110, 100, 95, 116, 97, 115,
        107, 0, 1, 3, 5, 4, 2, 1, 0, 1, 5, 3, 1, 0, 1, 6, 7, 1, 127, 1, 65,
        128, 8, 11, 7, 62, 5, 6, 109, 101, 109, 111, 114, 121, 2, 0, 12, 112,
        97, 116, 99, 104, 95, 109, 97, 108, 108, 111, 99, 0, 2, 10, 112, 97,
        116, 99, 104, 95, 102, 114, 101, 101, 0, 3, 10, 99, 97, 108, 108, 95,
        98, 101, 103, 105, 110, 0, 4, 8, 99, 97, 108, 108, 95, 101, 110, 100,
        0, 5, 10, 44, 4, 23, 1, 1, 127, 35, 0, 33, 1, 35, 0, 32, 0, 106, 65,
        7, 106, 65, 120, 113, 36, 0, 32, 1, 11, 2, 0, 11, 8, 0, 32, 0, 32, 1,
        16, 0, 11, 6, 0, 32, 0, 16, 1, 11,
    ]

    private func makeRuntime(_ bridge: BackgroundTaskBridge) throws -> WASMRuntime {
        let registry = BridgeRegistry().register(bridge)
        return try WASMRuntime(bytes: Self.fixture, hostImports: registry.hostImports())
    }

    func testBeginDecodesNameAndReturnsToken() throws {
        let spy = BGSpy()
        let rt = try makeRuntime(BackgroundTaskBridge(begin: spy.begin, end: spy.end))

        let (ptr, len) = try rt.writeBuffer([UInt8]("sync-upload".utf8))
        let result = try rt.invoke("call_begin", [.i32(ptr), .i32(len)])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(Int32(bitPattern: result[0].i32), 1, "first token is 1")
        XCTAssertEqual(spy.beganNames, ["sync-upload"])
    }

    func testBeginIncrementsTokenPerCall() throws {
        let spy = BGSpy()
        let rt = try makeRuntime(BackgroundTaskBridge(begin: spy.begin, end: spy.end))

        let (p1, l1) = try rt.writeBuffer([UInt8]("a".utf8))
        let t1 = Int32(bitPattern: try rt.invoke("call_begin", [.i32(p1), .i32(l1)])[0].i32)
        let (p2, l2) = try rt.writeBuffer([UInt8]("b".utf8))
        let t2 = Int32(bitPattern: try rt.invoke("call_begin", [.i32(p2), .i32(l2)])[0].i32)

        XCTAssertEqual(t1, 1)
        XCTAssertEqual(t2, 2)
        XCTAssertEqual(spy.beganNames, ["a", "b"])
    }

    func testEndForwardsToken() throws {
        let spy = BGSpy()
        let rt = try makeRuntime(BackgroundTaskBridge(begin: spy.begin, end: spy.end))

        let (ptr, len) = try rt.writeBuffer([UInt8]("task".utf8))
        let token = Int32(bitPattern: try rt.invoke("call_begin", [.i32(ptr), .i32(len)])[0].i32)
        _ = try rt.invoke("call_end", [.i32(UInt32(bitPattern: token))])

        XCTAssertEqual(spy.endedTokens, [token])
        XCTAssertEqual(spy.liveCount, 0, "begun then ended → nothing live")
    }

    /// Begin returning 0 (no background time) round-trips as 0 through the guest.
    func testBeginCanReturnZeroToken() throws {
        let spy = BGSpy(beginResult: 0)
        let rt = try makeRuntime(BackgroundTaskBridge(begin: spy.begin, end: spy.end))

        let (ptr, len) = try rt.writeBuffer([UInt8]("x".utf8))
        let result = try rt.invoke("call_begin", [.i32(ptr), .i32(len)])
        XCTAssertEqual(Int32(bitPattern: result[0].i32), 0)
    }

    #if canImport(UIKit)
    func testDefaultInitRegistersOnUIKit() throws {
        let registry = BridgeRegistry().register(BackgroundTaskBridge())
        XCTAssertNoThrow(try WASMRuntime(bytes: Self.fixture, hostImports: registry.hostImports()))
    }
    #endif
}

/// Thread-safe spy emulating the begin/end bookkeeping: hands out incrementing
/// tokens (or a fixed override) and tracks which are still "live".
private final class BGSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var next: Int32 = 1
    private var live: Set<Int32> = []
    private var _beganNames: [String] = []
    private var _endedTokens: [Int32] = []
    private let override: Int32?

    init(beginResult: Int32? = nil) { self.override = beginResult }

    var begin: BackgroundTaskBridge.Begin {
        { [self] name in
            lock.lock(); defer { lock.unlock() }
            _beganNames.append(name)
            if let override { return override }
            let t = next; next += 1; live.insert(t); return t
        }
    }
    var end: BackgroundTaskBridge.End {
        { [self] token in
            lock.lock(); _endedTokens.append(token); live.remove(token); lock.unlock()
        }
    }

    var beganNames: [String] { lock.lock(); defer { lock.unlock() }; return _beganNames }
    var endedTokens: [Int32] { lock.lock(); defer { lock.unlock() }; return _endedTokens }
    var liveCount: Int { lock.lock(); defer { lock.unlock() }; return live.count }
}
