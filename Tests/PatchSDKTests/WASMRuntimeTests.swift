import XCTest
import WasmKit
@testable import PatchSDK

/// Proves that real Swift-compiled `.wasm` modules instantiate under our runtime
/// (WASI Preview 1 satisfied) and that their exports run.
final class WASMRuntimeTests: XCTestCase {

    // Loads a committed fixture from the test bundle.
    private func fixture(_ name: String) throws -> [UInt8] {
        guard let url = Bundle.module.url(forResource: name, withExtension: "wasm") else {
            XCTFail("missing fixture \(name).wasm"); throw PatchRuntimeError.memoryMissing
        }
        return [UInt8](try Data(contentsOf: url))
    }

    /// The headline proof: load the real stdlib-only Swift module (14 WASI
    /// imports), instantiate with WASI satisfied + reactor `_initialize`, and
    /// invoke its `add` export.
    func testMinimalSwiftModuleInstantiatesAndRuns() throws {
        let bytes = try fixture("MinimalNoFoundation.release")
        let runtime = try WASMRuntime(bytes: bytes)

        XCTAssertTrue(runtime.hasFunction("add"), "module should export add")
        XCTAssertGreaterThan(try runtime.memorySize(), 0, "module should export memory")

        let r = try runtime.invoke("add", [.i32(40), .i32(2)])
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].i32, 42, "add(40,2) should be 42")

        // A few more to be sure it's really executing guest code.
        XCTAssertEqual(try runtime.invoke("add", [.i32(0xFFFFFFFF), .i32(1)])[0].i32, 0,
                       "wrapping add(-1,1) == 0")
    }

    /// The marshalling fixture exposes an allocator + string/data/scalar exports.
    func testMarshalFixtureScalarExports() throws {
        let runtime = try WASMRuntime(bytes: try fixture("MarshalFixture.release"))

        // i64 add
        let add = try runtime.invoke("add_i64", [.i64(UInt64(bitPattern: 1_000_000_000_000)),
                                                 .i64(UInt64(bitPattern: 234))])
        XCTAssertEqual(Int64(bitPattern: add[0].i64), 1_000_000_000_234)

        // f64 mul
        let mul = try runtime.invoke("mul_f64", [.f64((2.5).bitPattern), .f64((4.0).bitPattern)])
        XCTAssertEqual(Double(bitPattern: mul[0].f64), 10.0, accuracy: 1e-9)

        // bool not
        XCTAssertEqual(try runtime.invoke("not_bool", [.i32(0)])[0].i32, 1)
        XCTAssertEqual(try runtime.invoke("not_bool", [.i32(1)])[0].i32, 0)
    }

    /// Exercises the guest allocator + writing a string into linear memory and
    /// reading it back through an export.
    func testStringThroughLinearMemory() throws {
        let runtime = try WASMRuntime(bytes: try fixture("MarshalFixture.release"))

        let s = "héllo wörld"   // multi-byte UTF-8 to test byte vs char count
        let (ptr, len) = try runtime.writeBuffer([UInt8](s.utf8))
        defer { runtime.free(ptr) }

        // echo_len returns the decoded String's *character* count.
        let charCount = try runtime.invoke("echo_len", [.i32(ptr), .i32(len)])[0].i32
        XCTAssertEqual(Int(charCount), s.count)

        // Read the same bytes back out of guest memory directly.
        let back = try runtime.read(ptr: ptr, len: len)
        XCTAssertEqual(String(decoding: back, as: UTF8.self), s)
    }

    /// Exercises Data (raw bytes) round-trip + a guest-produced (ptr,len) blob.
    func testDataAndGuestProducedBlob() throws {
        let runtime = try WASMRuntime(bytes: try fixture("MarshalFixture.release"))

        let payload: [UInt8] = [1, 2, 3, 4, 250]   // sum = 260
        let (ptr, len) = try runtime.writeBuffer(payload)
        XCTAssertEqual(try runtime.invoke("sum_bytes", [.i32(ptr), .i32(len)])[0].i32, 260)

        // store_result reverses the bytes into a guest buffer; read it back.
        _ = try runtime.invoke("store_result", [.i32(ptr), .i32(len)])
        let outPtr = try runtime.invoke("last_result_ptr", [])[0].i32
        let outLen = try runtime.invoke("last_result_len", [])[0].i32
        let reversed = try runtime.read(ptr: outPtr, len: outLen)
        XCTAssertEqual(reversed, payload.reversed())
        runtime.free(ptr)
        runtime.free(outPtr)
    }

    /// Out-of-bounds reads are caught, not crashes.
    func testMemoryBoundsChecking() throws {
        let runtime = try WASMRuntime(bytes: try fixture("MarshalFixture.release"))
        let size = try runtime.memorySize()
        XCTAssertThrowsError(try runtime.read(ptr: UInt32(size), len: 16)) { err in
            guard case PatchRuntimeError.memoryOutOfBounds = err else {
                return XCTFail("expected memoryOutOfBounds, got \(err)")
            }
        }
    }

    /// Missing exports throw cleanly.
    func testMissingExportThrows() throws {
        let runtime = try WASMRuntime(bytes: try fixture("MinimalNoFoundation.release"))
        XCTAssertThrowsError(try runtime.invoke("does_not_exist")) { err in
            guard case PatchRuntimeError.exportNotFound = err else {
                return XCTFail("expected exportNotFound, got \(err)")
            }
        }
    }
}
