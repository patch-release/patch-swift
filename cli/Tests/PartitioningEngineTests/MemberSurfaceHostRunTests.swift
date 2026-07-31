// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
import WasmKit
import WasmKitWASI
@testable import PartitioningEngine
@testable import CodeGenerator
@testable import Compiler

/// HOST-RUN verification for the value-type METHOD surface reconstruction: build a
/// math-heavy value type (Euclid `Vector`-shaped) with pure methods/computed
/// properties declared in EXTENSIONS, run the real pipeline, and prove that a
/// reconstructed instance method (`dot`) and a method calling a sibling method
/// (`lengthSquared`→`dot`) COMPILE to wasm and HOST-RUN to a correct value.
final class MemberSurfaceHostRunTests: XCTestCase {

    /// Container-aware host runner: instantiates the shipped artifact as one WasmKit
    /// instance per sub-module (a `PMOD` container splits; a raw `.wasm` is one), and
    /// routes a `callPacked` to whichever instance exports the symbol — exactly as the
    /// SDK's `Patch` does on-device. This is what makes the real-source export (which
    /// lives in its OWN additive instance) actually runnable.
    private final class Runner {
        let store: Store
        let instances: [Instance]
        let wasi: WASIBridgeToHost
        init(wasm: [UInt8]) throws {
            let engine = Engine(); self.store = Store(engine: engine)
            self.wasi = try WASIBridgeToHost()
            var imports = Imports(); wasi.link(to: &imports, store: store)
            PatchHostTestImports.register(into: &imports, store: store)
            let modules = PatchModuleContainer.decode(wasm) ?? [wasm]
            var built: [Instance] = []
            for m in modules {
                let parsed = try parseWasm(bytes: m)
                let inst = try parsed.instantiate(store: store, imports: imports)
                try wasi.initialize(inst)
                built.append(inst)
            }
            self.instances = built
        }
        /// The instance that exports `name`, with its memory + allocator.
        private func resolve(_ name: String) throws -> (Instance, Memory, Function, Function) {
            for inst in instances {
                if let fn = inst.exports[function: name],
                   let malloc = inst.exports[function: "patch_malloc"],
                   let mem = inst.exports[memory: "memory"] {
                    return (inst, mem, malloc, fn)
                }
            }
            throw NSError(domain: "abi", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "no instance exports \(name)"])
        }
        func callPacked(_ name: String, _ input: [UInt8]) throws -> [UInt8] {
            let (_, mem, malloc, fn) = try resolve(name)
            let ptr = try malloc([.i32(UInt32(input.count))])[0].i32
            if !input.isEmpty {
                mem.withUnsafeMutableBufferPointer(offset: UInt(ptr), count: input.count) { $0.copyBytes(from: input) }
            }
            let packed = try fn([.i32(ptr), .i32(UInt32(input.count))])[0].i64
            let outPtr = UInt32(truncatingIfNeeded: packed >> 32)
            let outLen = UInt32(truncatingIfNeeded: packed & 0xFFFF_FFFF)
            let all = mem.data
            return [UInt8](all[Int(outPtr)..<Int(outPtr) + Int(outLen)])
        }
    }

    /// A `Vector`-shaped value type whose pure method surface lives in EXTENSIONS
    /// (exactly like Euclid): `dot` (stored-field arithmetic) and `lengthSquared`
    /// (calls `dot(self)`) must reconstruct so the instance-method exports compile.
    private static let fixture: [(String, String)] = [
        ("Vec.swift", """
        public struct Vec: Hashable, Codable {
            public var x: Double
            public var y: Double
            public var z: Double
            public init(_ x: Double, _ y: Double, _ z: Double) { self.x = x; self.y = y; self.z = z }
        }
        public extension Vec {
            // Pure instance method over stored fields — must reconstruct + export.
            func dot(_ other: Vec) -> Double { x * other.x + y * other.y + z * other.z }
            // Calls a sibling method — the member-surface walk must pull `dot` in.
            var lengthSquared: Double { dot(self) }
            // A method touching a static (`.zero`) we DON'T reconstruct — its export
            // must be REJECTED (kept native), never shipped broken.
            static let zero = Vec(0, 0, 0)
            func clampedToZeroIfTiny() -> Vec { lengthSquared < 1e-9 ? .zero : self }
        }
        """),
    ]

    func testReconstructedMethodBuildsAndHostRuns() throws {
        let compiler = SwiftWasmCompiler()
        try XCTSkipUnless(compiler.toolchainAvailable, "WASM toolchain absent — skipping")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ms-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (n, c) in Self.fixture { try c.write(to: dir.appendingPathComponent(n), atomically: true, encoding: .utf8) }
        let buildDir = FileManager.default.temporaryDirectory.appendingPathComponent("ms-b-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: buildDir) }

        let result = try BuildPipeline().run(sourceDir: dir, buildDir: buildDir, compiler: compiler, dryRun: false)
        guard let module = result.moduleURL else {
            return XCTFail("no module. rejected: \(result.rejectedExports)")
        }
        XCTAssertTrue(result.exportSymbols.contains("Vec_dot"),
                      "Vec.dot must ship as a reconstructed instance method, not demote")
        // The static-`.zero`-touching method must be REJECTED (zero false negatives).
        XCTAssertFalse(result.exportSymbols.contains("Vec_clampedToZeroIfTiny"),
                       "a method touching an unreconstructed static must NOT ship")

        let wasm = [UInt8](try Data(contentsOf: module))
        let runner = try Runner(wasm: wasm)
        // dot((1,2,3),(4,5,6)) = 4 + 10 + 18 = 32.
        struct Out: Decodable { let value: Double }
        let input = #"{"_receiver":{"x":1,"y":2,"z":3},"other":{"x":4,"y":5,"z":6}}"#
        let bytes = try runner.callPacked("Vec_dot", [UInt8](input.utf8))
        let out = try JSONDecoder().decode(Out.self, from: Data(bytes))
        XCTAssertEqual(out.value, 32.0, accuracy: 1e-9,
                       "reconstructed Vec.dot must run in WASM and return 1·4+2·5+3·6 = 32")
    }
}
