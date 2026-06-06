import XCTest
import WasmKit
@testable import PatchSDK

/// NfcReadBridge — host bridge for beginning an NFC NDEF read session.
///
/// Two layers under test:
///   1. `normalizePrompt(_:)` — the pure prompt-normalisation logic (trim, blank
///      → default).
///   2. Dispatch of `begin_nfc_read(ptr,len)` through a hand-built wasm module
///      (imports `patch.begin_nfc_read`, exports `call_f(i32,i32)` plus
///      memory/malloc/free). A spy stands in for NFCNDEFReaderSession.
final class NfcReadBridgeTests: XCTestCase {

    private static let fixture: [UInt8] = [
        0, 97, 115, 109, 1, 0, 0, 0, 1, 15, 3, 96, 2, 127, 127, 0, 96, 1, 127, 1, 127,
        96, 1, 127, 0, 2, 24, 1, 5, 112, 97, 116, 99, 104, 14, 98, 101, 103,
        105, 110, 95, 110, 102, 99, 95, 114, 101, 97, 100, 0, 0, 3, 4, 3, 1,
        2, 0, 5, 3, 1, 0, 1, 6, 7, 1, 127, 1, 65, 128, 8, 11, 7, 47, 4, 6,
        109, 101, 109, 111, 114, 121, 2, 0, 12, 112, 97, 116, 99, 104, 95,
        109, 97, 108, 108, 111, 99, 0, 1, 10, 112, 97, 116, 99, 104, 95, 102,
        114, 101, 101, 0, 2, 6, 99, 97, 108, 108, 95, 102, 0, 3, 10, 37, 3,
        23, 1, 1, 127, 35, 0, 33, 1, 35, 0, 32, 0, 106, 65, 7, 106, 65, 120,
        113, 36, 0, 32, 1, 11, 2, 0, 11, 8, 0, 32, 0, 32, 1, 16, 0, 11,
    ]

    private static let defaultPrompt = "Hold your iPhone near the tag."

    // MARK: - normalizePrompt(_:) pure logic

    func testNormalizeKeepsRealPrompt() {
        XCTAssertEqual(NfcReadBridge.normalizePrompt("Scan your loyalty card"),
                       "Scan your loyalty card")
    }

    func testNormalizeTrimsWhitespace() {
        XCTAssertEqual(NfcReadBridge.normalizePrompt("  Scan now \n"), "Scan now")
    }

    func testNormalizeBlankFallsBackToDefault() {
        XCTAssertEqual(NfcReadBridge.normalizePrompt(""), Self.defaultPrompt)
        XCTAssertEqual(NfcReadBridge.normalizePrompt("   \n\t "), Self.defaultPrompt)
    }

    // MARK: - Dispatch through the wasm fixture

    func testDispatchNormalizesAndInvokes() throws {
        let spy = NfcSpy()
        let rt = try WASMRuntime(
            bytes: Self.fixture,
            hostImports: BridgeRegistry().register(NfcReadBridge(present: spy.present)).hostImports())

        let (ptr, len) = try rt.writeBuffer([UInt8]("  Tap the tag  ".utf8))
        _ = try rt.invoke("call_f", [.i32(ptr), .i32(len)])

        XCTAssertEqual(spy.prompts, ["Tap the tag"], "host trims before presenting")
    }

    func testDispatchBlankPromptUsesDefault() throws {
        let spy = NfcSpy()
        let rt = try WASMRuntime(
            bytes: Self.fixture,
            hostImports: BridgeRegistry().register(NfcReadBridge(present: spy.present)).hostImports())

        let (ptr, len) = try rt.writeBuffer([UInt8]("".utf8))
        _ = try rt.invoke("call_f", [.i32(ptr), .i32(len)])

        XCTAssertEqual(spy.prompts, [Self.defaultPrompt])
    }

    #if canImport(CoreNFC)
    func testDefaultInitRegistersOnCoreNFC() throws {
        let registry = BridgeRegistry().register(NfcReadBridge())
        XCTAssertNoThrow(try WASMRuntime(bytes: Self.fixture, hostImports: registry.hostImports()))
    }
    #endif
}

private final class NfcSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _prompts: [String] = []
    var present: NfcReadBridge.Present {
        { [self] p in lock.lock(); _prompts.append(p); lock.unlock() }
    }
    var prompts: [String] { lock.lock(); defer { lock.unlock() }; return _prompts }
}
