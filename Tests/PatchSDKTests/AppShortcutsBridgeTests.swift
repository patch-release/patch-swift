import XCTest
import WasmKit
@testable import PatchSDK

/// AppShortcutsBridge — host bridge for dynamic home-screen quick actions.
///
/// Two layers under test:
///   1. `parse(_:)` — the pure JSON→`[QuickAction]` decode (required `type`,
///      title defaulting, optional subtitle/image, string userInfo, dropping of
///      malformed elements, invalid JSON → empty).
///   2. Dispatch of `set_shortcuts(ptr,len)` through a hand-built wasm module
///      (imports `patch.set_shortcuts`, exports `call_f(i32,i32)` plus
///      memory/malloc/free). A spy stands in for UIApplication.shortcutItems.
final class AppShortcutsBridgeTests: XCTestCase {

    private static let fixture: [UInt8] = [
        0, 97, 115, 109, 1, 0, 0, 0, 1, 15, 3, 96, 2, 127, 127, 0, 96, 1, 127, 1, 127,
        96, 1, 127, 0, 2, 23, 1, 5, 112, 97, 116, 99, 104, 13, 115, 101, 116,
        95, 115, 104, 111, 114, 116, 99, 117, 116, 115, 0, 0, 3, 4, 3, 1, 2,
        0, 5, 3, 1, 0, 1, 6, 7, 1, 127, 1, 65, 128, 8, 11, 7, 47, 4, 6, 109,
        101, 109, 111, 114, 121, 2, 0, 12, 112, 97, 116, 99, 104, 95, 109, 97,
        108, 108, 111, 99, 0, 1, 10, 112, 97, 116, 99, 104, 95, 102, 114, 101,
        101, 0, 2, 6, 99, 97, 108, 108, 95, 102, 0, 3, 10, 37, 3, 23, 1, 1,
        127, 35, 0, 33, 1, 35, 0, 32, 0, 106, 65, 7, 106, 65, 120, 113, 36, 0,
        32, 1, 11, 2, 0, 11, 8, 0, 32, 0, 32, 1, 16, 0, 11,
    ]

    // MARK: - parse(_:) pure decode

    func testParseFullAction() {
        let actions = AppShortcutsBridge.parse(Array(#"""
        [{"type":"com.acme.new","title":"New","subtitle":"Create one",
          "systemImageName":"plus","userInfo":{"k":"v","n":"2"}}]
        """#.utf8))
        XCTAssertEqual(actions.count, 1)
        let a = actions[0]
        XCTAssertEqual(a.type, "com.acme.new")
        XCTAssertEqual(a.title, "New")
        XCTAssertEqual(a.subtitle, "Create one")
        XCTAssertEqual(a.systemImageName, "plus")
        XCTAssertEqual(a.userInfo, ["k": "v", "n": "2"])
    }

    func testParseTitleDefaultsToType() {
        let actions = AppShortcutsBridge.parse(Array(#"[{"type":"a.b.c"}]"#.utf8))
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0].title, "a.b.c", "missing title → type")
        XCTAssertNil(actions[0].subtitle)
        XCTAssertNil(actions[0].systemImageName)
        XCTAssertTrue(actions[0].userInfo.isEmpty)
    }

    func testParseDropsElementsMissingType() {
        let actions = AppShortcutsBridge.parse(Array(#"""
        [{"title":"no type"},{"type":""},{"type":"keep","title":"Keep"},42,"str"]
        """#.utf8))
        XCTAssertEqual(actions.map(\.type), ["keep"], "only the valid-typed element survives")
    }

    func testParseUserInfoDropsNonStringValues() {
        let actions = AppShortcutsBridge.parse(Array(#"""
        [{"type":"t","userInfo":{"keep":"yes","num":5,"obj":{"x":1}}}]
        """#.utf8))
        XCTAssertEqual(actions[0].userInfo, ["keep": "yes"])
    }

    func testParseInvalidJSONYieldsEmpty() {
        XCTAssertTrue(AppShortcutsBridge.parse(Array("not json".utf8)).isEmpty)
        XCTAssertTrue(AppShortcutsBridge.parse(Array("{}".utf8)).isEmpty, "object (not array) → empty")
        XCTAssertTrue(AppShortcutsBridge.parse([]).isEmpty)
    }

    func testParsePreservesOrder() {
        let actions = AppShortcutsBridge.parse(Array(#"""
        [{"type":"one"},{"type":"two"},{"type":"three"}]
        """#.utf8))
        XCTAssertEqual(actions.map(\.type), ["one", "two", "three"])
    }

    // MARK: - Dispatch through the wasm fixture

    func testDispatchDecodesAndInvokes() throws {
        let spy = ShortcutsSpy()
        let rt = try WASMRuntime(
            bytes: Self.fixture,
            hostImports: BridgeRegistry().register(AppShortcutsBridge(setShortcuts: spy.set)).hostImports())

        let json = #"[{"type":"x.y","title":"T"},{"type":"a.b"}]"#
        let (ptr, len) = try rt.writeBuffer([UInt8](json.utf8))
        _ = try rt.invoke("call_f", [.i32(ptr), .i32(len)])

        XCTAssertEqual(spy.calls.count, 1)
        XCTAssertEqual(spy.calls.first?.map(\.type), ["x.y", "a.b"])
        XCTAssertEqual(spy.calls.first?.first?.title, "T")
    }

    func testDispatchEmptyArrayClears() throws {
        let spy = ShortcutsSpy()
        let rt = try WASMRuntime(
            bytes: Self.fixture,
            hostImports: BridgeRegistry().register(AppShortcutsBridge(setShortcuts: spy.set)).hostImports())

        let (ptr, len) = try rt.writeBuffer([UInt8]("[]".utf8))
        _ = try rt.invoke("call_f", [.i32(ptr), .i32(len)])

        XCTAssertEqual(spy.calls.count, 1)
        XCTAssertEqual(spy.calls.first?.count, 0, "empty array clears all shortcuts")
    }

    #if canImport(UIKit)
    func testDefaultInitRegistersOnUIKit() throws {
        let registry = BridgeRegistry().register(AppShortcutsBridge())
        XCTAssertNoThrow(try WASMRuntime(bytes: Self.fixture, hostImports: registry.hostImports()))
    }
    #endif
}

private final class ShortcutsSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[QuickAction]] = []
    var set: AppShortcutsBridge.Setter {
        { [self] actions in lock.lock(); _calls.append(actions); lock.unlock() }
    }
    var calls: [[QuickAction]] { lock.lock(); defer { lock.unlock() }; return _calls }
}
