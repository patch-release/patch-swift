import XCTest
import WasmKit
@testable import PatchSDK

/// Bounds-checking on the bridge WRITE path (`BridgeContext.writeBytes`).
///
/// A host bridge that returns bytes allocates a guest buffer via the guest's
/// exported `patch_malloc` and writes into it. `patch_malloc` is guest-controlled:
/// a buggy or hostile allocator can return a pointer near (or past) the end of
/// linear memory. The host must bounds-check that pointer BEFORE writing — the
/// read path (`readBytes`) already did, but the write path used to trust the
/// allocator blindly and write out of bounds (memory corruption / trap).
final class BridgeContextBoundsTests: XCTestCase {

    // Hand-written wasm (wat2wasm). One 64 KiB page; `patch_malloc` ALWAYS returns
    // 70000 — past the page end — to simulate a hostile/buggy allocator. The
    // exported `call_locale` invokes the `patch.locale_identifier` host bridge,
    // which tries to write the locale string into guest memory at that bad ptr.
    //
    // (module
    //   (import "patch" "locale_identifier" (func $locale (result i64)))
    //   (memory (export "memory") 1)
    //   (func (export "patch_malloc") (param i32) (result i32) i32.const 70000)
    //   (func (export "call_locale") (result i64) call $locale))
    private static let badMallocWasm: [UInt8] = [
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x0a, 0x02, 0x60,
        0x00, 0x01, 0x7e, 0x60, 0x01, 0x7f, 0x01, 0x7f, 0x02, 0x1b, 0x01, 0x05,
        0x70, 0x61, 0x74, 0x63, 0x68, 0x11, 0x6c, 0x6f, 0x63, 0x61, 0x6c, 0x65,
        0x5f, 0x69, 0x64, 0x65, 0x6e, 0x74, 0x69, 0x66, 0x69, 0x65, 0x72, 0x00,
        0x00, 0x03, 0x03, 0x02, 0x01, 0x00, 0x05, 0x03, 0x01, 0x00, 0x01, 0x07,
        0x27, 0x03, 0x06, 0x6d, 0x65, 0x6d, 0x6f, 0x72, 0x79, 0x02, 0x00, 0x0c,
        0x70, 0x61, 0x74, 0x63, 0x68, 0x5f, 0x6d, 0x61, 0x6c, 0x6c, 0x6f, 0x63,
        0x00, 0x01, 0x0b, 0x63, 0x61, 0x6c, 0x6c, 0x5f, 0x6c, 0x6f, 0x63, 0x61,
        0x6c, 0x65, 0x00, 0x02, 0x0a, 0x0d, 0x02, 0x06, 0x00, 0x41, 0xf0, 0xa2,
        0x04, 0x0b, 0x04, 0x00, 0x10, 0x00, 0x0b,
    ]

    /// The host bridge must REJECT (throw) a write at an out-of-range allocator
    /// pointer rather than write out of bounds. `locale_identifier` returns a
    /// non-empty string, so `writeBytes` is exercised with a real payload.
    func testWriteBytesRejectsOutOfBoundsAllocatorPointer() throws {
        // A fixed, non-empty locale so the host attempts a real write.
        let bridge = DateLocaleBridge(locale: { Locale(identifier: "en_US") })
        let registry = BridgeRegistry().register(bridge)
        let rt = try WASMRuntime(bytes: Self.badMallocWasm, hostImports: registry.hostImports())

        // Invoking the trampoline drives the host bridge → writeBytes at ptr 70000
        // (past the single 64 KiB page). With the bounds check this throws cleanly;
        // without it the host wrote out of bounds. Either way the call must not
        // succeed silently — assert it throws.
        XCTAssertThrowsError(try rt.invoke("call_locale")) { _ in
            // Any thrown error (the OOB surfaces as a trap through the guest call)
            // is acceptable — the contract is "do not write out of bounds".
        }
    }
}
