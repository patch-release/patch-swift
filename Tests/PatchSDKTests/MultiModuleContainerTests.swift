import XCTest
import WasmKit
@testable import PatchSDK

/// THE on-device regression test for the multi-memory P0 (Option B / `PMOD` container).
///
/// A real-source build ships the DEFAULT-engine module + an additive real-source module
/// as ONE `PMOD` container. The two are INDEPENDENTLY-linked Swift modules (each with its
/// own memory/allocator/`_initialize`), so they CANNOT be fused into one wasm module the
/// device runtime can run — a fused module is either multi-memory (WasmKit refuses it) or
/// runs the second module against the wrong heap. The SDK therefore instantiates EACH
/// sub-module as its OWN `WASMRuntime` and ROUTES each call to the instance that exports
/// the symbol. These tests prove that routing works through the real `Patch` façade.
///
/// The two fixtures play the two roles:
///   - `MinimalNoFoundation.release` (the DEFAULT module) exports `add(i32,i32)->i32`.
///   - `MarshalFixture.release` (the ADDITIVE real-source module) exports `mul_f64`,
///     `not_bool`, `add_i64`, … — a DISJOINT export set the default module lacks.
final class MultiModuleContainerTests: XCTestCase {

    private func fixture(_ name: String) throws -> [UInt8] {
        guard let url = Bundle.module.url(forResource: name, withExtension: "wasm") else {
            XCTFail("missing fixture \(name).wasm"); throw PatchRuntimeError.memoryMissing
        }
        return [UInt8](try Data(contentsOf: url))
    }

    /// Activate a 2-module `PMOD` container and prove BOTH a default-module export AND an
    /// additive-module export EXECUTE and return CORRECT values through `Patch.call` —
    /// each routed to its own WasmKit instance. This is the test that would have caught
    /// the shipped-but-uninstantiable merged module.
    func testContainerRoutesCallsToBothInstances() throws {
        let defaultModule = try fixture("MinimalNoFoundation.release")   // exports `add`
        let additive = try fixture("MarshalFixture.release")             // exports `mul_f64`, `not_bool`, ...
        let container = PatchModuleContainer.encode([defaultModule, additive])
        XCTAssertTrue(PatchModuleContainer.isContainer(container))

        let patch = Patch()
        try patch.activate(bytes: container)
        XCTAssertTrue(patch.hasActiveModule)

        // Both instances' exports are visible through routing.
        XCTAssertTrue(patch.hasFunction("add"), "default-module export must be routable")
        XCTAssertTrue(patch.hasFunction("not_bool"), "additive-module export must be routable")
        XCTAssertFalse(patch.hasFunction("definitely_not_an_export"))

        // DEFAULT export → routes to instance 0, executes correctly.
        let sum = try patch.call("add", [.i32(40), .i32(2)])
        XCTAssertEqual(sum[0].i32, 42, "default `add(40,2)` must execute on its own instance")

        // ADDITIVE (real-source) export → routes to instance 1, executes correctly.
        // (5*6+... — `add_i64` is the additive module's integer add: 5+6=11.)
        let addI64 = try patch.call("add_i64", [.i64(5), .i64(6)])
        XCTAssertEqual(Int64(bitPattern: addI64[0].i64), 11,
                       "additive `add_i64(5,6)` must execute on its own instance — the P0 gain")
        // not_bool flips a Bool — exercise the additive instance's linear memory path.
        XCTAssertEqual(try patch.call("not_bool", [.i32(0)])[0].i32, 1)
        XCTAssertEqual(try patch.call("not_bool", [.i32(1)])[0].i32, 0)

        // A function NO instance exports routes nowhere → exportNotFound.
        XCTAssertThrowsError(try patch.call("nope_missing")) { err in
            guard case PatchError.runtime(.exportNotFound) = err else {
                return XCTFail("expected exportNotFound, got \(err)")
            }
        }
    }

    /// `callPacked` (the structured-blob ABI the engine's generated exports use) also
    /// routes to the right instance. The additive `MarshalFixture` exports
    /// `reverse_packed` (a (ptr,len)->packed export); calling it through a container must
    /// execute on the additive instance's OWN linear memory and return the reversed bytes.
    func testCallPackedRoutesToAdditiveInstance() throws {
        let defaultModule = try fixture("MinimalNoFoundation.release")   // NO reverse_packed
        let additive = try fixture("MarshalFixture.release")            // HAS reverse_packed
        let container = PatchModuleContainer.encode([defaultModule, additive])

        let patch = Patch()
        try patch.activate(bytes: container)

        let input: [UInt8] = Array("PatchSDK".utf8)
        let out = try patch.callPacked("reverse_packed", input)
        XCTAssertEqual(out, input.reversed(),
                       "callPacked must route to the additive instance and use ITS linear memory")
    }

    /// Back-compat: a RAW single `.wasm` (not a container) still activates as one module
    /// and its exports run — the legacy path is unchanged.
    func testRawSingleModuleStillWorks() throws {
        let patch = Patch()
        try patch.activate(bytes: try fixture("MinimalNoFoundation.release"))
        XCTAssertTrue(patch.hasActiveModule)
        XCTAssertTrue(patch.hasFunction("add"))
        XCTAssertEqual(try patch.call("add", [.i32(1), .i32(2)])[0].i32, 3)
    }

    /// Hot-swapping a single module → a container (and back) works: the active set is
    /// replaced atomically and routing follows the new set.
    func testHotSwapBetweenSingleAndContainer() throws {
        let defaultModule = try fixture("MinimalNoFoundation.release")
        let additive = try fixture("MarshalFixture.release")
        let patch = Patch()

        // Start with a single module (only `add`).
        try patch.activate(bytes: defaultModule)
        XCTAssertTrue(patch.hasFunction("add"))
        XCTAssertFalse(patch.hasFunction("not_bool"))

        // Hot-swap to a container — now `not_bool` (additive) is routable too.
        try patch.hotSwap(bytes: PatchModuleContainer.encode([defaultModule, additive]))
        XCTAssertTrue(patch.hasFunction("add"))
        XCTAssertTrue(patch.hasFunction("not_bool"))
        XCTAssertEqual(try patch.call("not_bool", [.i32(0)])[0].i32, 1)

        // Hot-swap back to the single module — the additive export is gone again.
        try patch.hotSwap(bytes: defaultModule)
        XCTAssertTrue(patch.hasFunction("add"))
        XCTAssertFalse(patch.hasFunction("not_bool"))
    }
}
