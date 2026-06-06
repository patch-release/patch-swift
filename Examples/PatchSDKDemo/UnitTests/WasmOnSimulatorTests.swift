import XCTest
import PatchSDK
import WasmKit

/// Unit-style XCTest that runs *inside the app process on the simulator* (hosted
/// test bundle). It exercises `WASMRuntime` directly — no UI — so it's the robust
/// headless proof that WasmKit instantiates and invokes WebAssembly on the
/// CoreSimulator runtime, even if a full UI launch is flaky in CI.
final class WasmOnSimulatorTests: XCTestCase {

    /// The tiny hand-written `demo.wasm`: scalar + (ptr,len) ABI.
    func testDemoModuleRunsOnSimulator() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "demo", withExtension: "wasm"))
        let bytes = [UInt8](try Data(contentsOf: url))
        let runtime = try WASMRuntime(bytes: bytes)

        XCTAssertEqual(try runtime.invoke("add", [.i32(40), .i32(2)])[0].i32, 42)
        XCTAssertEqual(Int64(bitPattern: try runtime.invoke("fib", [.i32(20)])[0].i64), 6765)

        let inBytes = [UInt8]("PatchSDK".utf8)
        let (ptr, len) = try runtime.writeBuffer(inBytes)
        let packed = try runtime.invoke("reverse", [.i32(ptr), .i32(len)])[0].i64
        let out = try runtime.read(ptr: UInt32(packed >> 32), len: UInt32(packed & 0xFFFF_FFFF))
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "KDShctaP")
    }

    /// A REAL Swift-compiled `wasm32-unknown-wasip1` reactor module (5.5 MB,
    /// 14 WASI imports, exports `add` + `_initialize`). Proves WasmKitWASI's
    /// Preview 1 host and reactor `_initialize` work on the simulator runtime —
    /// the same thing real Patch OTA modules need.
    func testRealSwiftModuleRunsOnSimulator() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "MinimalSwift", withExtension: "wasm"))
        let bytes = [UInt8](try Data(contentsOf: url))
        let runtime = try WASMRuntime(bytes: bytes)  // WASI satisfied + _initialize called
        XCTAssertEqual(try runtime.invoke("add", [.i32(40), .i32(2)])[0].i32, 42)
    }
}
