import Foundation
import os
import PatchSDK
import WasmKit

/// Drives a real `WASMRuntime` against the bundled `demo.wasm`, exercising both a
/// plain scalar export and the Patch v0 `(ptr,len)` string ABI. Everything here
/// runs identically on the iOS Simulator, a device, and macOS — it only depends
/// on `PatchSDK` + `WasmKit`, no host bridges and no WASI capabilities.
enum DemoRuntime {
    /// os_log subsystem/category the UI test (and `simctl spawn log`) greps for.
    static let log = Logger(subsystem: "dev.patch.PatchSDKDemo", category: "demo")

    struct Result: Sendable {
        let moduleBytes: Int
        let add: Int32          // add(40, 2)
        let fib: Int64          // fib(20)
        let reversed: String    // reverse("PatchSDK")
        let ok: Bool
    }

    /// Locate the bundled demo module.
    static func moduleURL() throws -> URL {
        guard let url = Bundle.main.url(forResource: "demo", withExtension: "wasm") else {
            throw NSError(domain: "PatchSDKDemo", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "demo.wasm not in bundle"])
        }
        return url
    }

    /// Load + instantiate the module via `WASMRuntime` and run the three exports.
    /// Throws on any runtime/marshalling failure so the UI can surface it.
    static func run() throws -> Result {
        let url = try moduleURL()
        let bytes = [UInt8](try Data(contentsOf: url))
        log.info("PATCHDEMO loading demo.wasm (\(bytes.count, privacy: .public) bytes)")

        // Real WasmKit instantiation on this runtime (Simulator/device/macOS).
        let runtime = try WASMRuntime(bytes: bytes)
        let memBytes = try runtime.memorySize()
        log.info("PATCHDEMO WASMRuntime instantiated; memory=\(memBytes, privacy: .public) bytes")

        // 1. Scalar export: add(40, 2) -> i32
        let addResults = try runtime.invoke("add", [.i32(40), .i32(2)])
        let add = Int32(bitPattern: addResults[0].i32)

        // 2. Heavier compute: fib(20) -> i64  (expected 6765)
        let fibResults = try runtime.invoke("fib", [.i32(20)])
        let fib = Int64(bitPattern: fibResults[0].i64)

        // 3. (ptr,len) string ABI: reverse("PatchSDK") via guest malloc + memory.
        let input = "PatchSDK"
        let inBytes = [UInt8](input.utf8)
        let (inPtr, inLen) = try runtime.writeBuffer(inBytes)
        let packed = try runtime.invoke("reverse", [.i32(inPtr), .i32(inLen)]).first!.i64
        let outPtr = UInt32(packed >> 32)
        let outLen = UInt32(packed & 0xFFFF_FFFF)
        let outBytes = try runtime.read(ptr: outPtr, len: outLen)
        let reversed = String(decoding: outBytes, as: UTF8.self)
        runtime.free(inPtr)
        runtime.free(outPtr)

        let ok = (add == 42) && (fib == 6765) && (reversed == "KDShctaP")
        log.info("PATCHDEMO results add=\(add, privacy: .public) fib=\(fib, privacy: .public) reverse=\(reversed, privacy: .public) ok=\(ok, privacy: .public)")
        if ok {
            log.info("PATCHDEMO SUCCESS: WasmKit executed demo.wasm via PatchSDK on this runtime")
        } else {
            log.error("PATCHDEMO FAILURE: unexpected results")
        }

        return Result(moduleBytes: bytes.count, add: add, fib: fib,
                      reversed: reversed, ok: ok)
    }
}
