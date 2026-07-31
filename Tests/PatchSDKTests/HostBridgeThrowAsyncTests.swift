// SPDX-License-Identifier: MIT

import XCTest
import Foundation
@testable import PatchHostBridge

// ===========================================================================
// LEVER #2 — THROWING + ASYNC native symbols (DESIGN §8.7).
//
// The core generalized bridge (PatchHostBridge) routes a SYNCHRONOUS scalar /
// value / handle-proxy call value-exact through WasmKit (proven in
// GenericHostBridgeTests / HostBridgeVerticalSliceTests). This file proves the
// two §8.7 extensions:
//
//   THROWING (the cheap, high-value half): a registered thunk for a `throws`
//   symbol wraps the native call in `do { … } catch { return .error(…) }`. The
//   `.error` TLV tag IS the demote channel — a thrown native error routes the
//   guest to its native fallback. Proven: a throwing thunk that SUCCEEDS returns
//   the exact value; one that THROWS returns a tagged `.error` (no crash).
//
//   ASYNC (the additive half): an `async` native symbol composes with the
//   existing async pump + a continuation, exactly as the networking bridge does.
//   The guest suspends on a token via `patch_host.call_async`; the host captures
//   the pending call (PatchAsyncCallBroker), runs the registered async thunk to
//   completion on host concurrency from the pump stall, writes the TLV result
//   blob into guest memory, and resumes the guest via `patch_resolve_hostcall`.
//   Proven here at the WIRING level (the broker drives the registered async thunk
//   and delivers the right result blob to the right token via injected
//   write/invoke closures — the same shape `GenericHostBridge.asyncResolve` wires
//   to a real `WASMRuntime`), plus the failure/timeout demote paths.
// ===========================================================================

// MARK: - "Already-linked native code" the routed throwing/async calls resolve to.

private enum ParseError: Error, CustomStringConvertible {
    case notANumber(String)
    var description: String { if case .notANumber(let s) = self { return "not a number: \(s)" }; return "parse error" }
}

private enum Parser {
    /// A real THROWING native symbol (the engine could not reconstruct it).
    static func parse(_ s: String) throws -> Int {
        guard let v = Int(s) else { throw ParseError.notANumber(s) }
        return v
    }
}

private enum Store {
    /// A real ASYNC native symbol — `await`s some host work, returns a scalar.
    static func priceCents(_ sku: String) async -> Int {
        // A tiny real suspension point (no executor needed in the host — this is the
        // SDK side, full Swift concurrency) so the await path is genuinely exercised.
        await Task.yield()
        return sku == "gold" ? 1299 : 499
    }

    /// A real ASYNC THROWING native symbol — both effects compose.
    static func load(_ key: String) async throws -> String {
        await Task.yield()
        guard key != "missing" else { throw ParseError.notANumber(key) }
        return "loaded:\(key)"
    }
}

final class HostBridgeThrowAsyncTests: XCTestCase {

    // =======================================================================
    // MARK: - THROWING half (fully) — the .error demote channel
    // =======================================================================

    private func makeThrowingBridge() -> PatchHostBridge {
        let bridge = PatchHostBridge()
        // This is character-for-character the closure the engine's
        // HostBridgeThunkGenerator(target: .realSDK) emits for a `throws` symbol:
        //   bridge.register(id:…) { (args, handles) throws -> TLVValue in
        //       do { return .i64(Int64(try Parser.parse(try args.string(0)))) }
        //       catch { return .error("\(error)") }
        //   }
        bridge.register(id: 501, signature: "MyApp.Parser.parse(String)->Int") { args, _ in
            do {
                return .i64(Int64(try Parser.parse(try args.string(0))))
            } catch {
                return .error("\(error)")
            }
        }
        return bridge
    }

    /// A throwing thunk that SUCCEEDS returns the exact native value.
    func testThrowingThunkSucceedsReturnsValue() throws {
        let bridge = makeThrowingBridge()
        let blob = TLVCodec.encodeArgs([.string("42")])
        let result = bridge.call(501, argsBlob: blob)
        XCTAssertEqual(result, .i64(42), "a successful throwing call returns the native value")
        // Host truth: Parser.parse("42") == 42.
        XCTAssertEqual(try Parser.parse("42"), 42)
    }

    /// A throwing thunk that THROWS returns a tagged `.error` — DEMOTE-SAFE: no crash,
    /// the error message is carried, and the guest's emitted wrapper treats any `.error`
    /// as "go native". This is the load-bearing throwing property.
    func testThrowingThunkThrowsReturnsTaggedError() throws {
        let bridge = makeThrowingBridge()
        let blob = TLVCodec.encodeArgs([.string("not-a-number")])
        let result = bridge.call(501, argsBlob: blob)
        guard case .error(let msg) = result else {
            return XCTFail("a thrown native error must surface as a tagged .error, got \(result)")
        }
        XCTAssertTrue(msg.contains("not a number") || msg.contains("not-a-number"),
                      "the .error carries the thrown error's description: \(msg)")
        // And the native symbol genuinely throws for this input (the error is real, not faked).
        XCTAssertThrowsError(try Parser.parse("not-a-number"))
    }

    /// The dispatcher ALSO converts a thunk's UNCAUGHT throw to `.error` (a thunk that
    /// does NOT wrap in do/catch is still demote-safe — `PatchHostBridge.call`'s own
    /// catch is the backstop). Proves the demote channel holds even if a thunk forgets
    /// the wrapper.
    func testUnwrappedThrowStillDemotesSafely() throws {
        let bridge = PatchHostBridge()
        bridge.register(id: 510, signature: "throwsAlways") { args, _ in
            // No do/catch — the native throw propagates; the dispatcher catches it.
            .i64(Int64(try Parser.parse(try args.string(0))))
        }
        let result = bridge.call(510, argsBlob: TLVCodec.encodeArgs([.string("nope")]))
        guard case .error = result else {
            return XCTFail("an uncaught thunk throw must still become a tagged .error, got \(result)")
        }
    }

    // =======================================================================
    // MARK: - ASYNC half (fully) — registerAsync + the continuation broker
    // =======================================================================

    private func makeAsyncBridge() -> PatchHostBridge {
        let bridge = PatchHostBridge()
        // The engine's HostBridgeThunkGenerator(target: .realSDK) emits, for an `async`
        // symbol: bridge.registerAsync(id:…) { (args, handles) async throws -> TLVValue in
        //             return .i64(Int64(await Store.priceCents(try args.string(0)))) }
        bridge.registerAsync(id: 601, signature: "MyApp.Store.priceCents(String)->Int") { args, _ in
            .i64(Int64(await Store.priceCents(try args.string(0))))
        }
        // An `async throws` symbol — both effects: `try await …` in do/catch.
        bridge.registerAsync(id: 602, signature: "MyApp.Store.load(String)->String") { args, _ in
            do {
                return .string(try await Store.load(try args.string(0)))
            } catch {
                return .error("\(error)")
            }
        }
        return bridge
    }

    /// `haveAsync` reflects async-registry membership (the analogue of `have`).
    func testHaveAsyncReflectsRegistry() {
        let bridge = makeAsyncBridge()
        XCTAssertTrue(bridge.haveAsync(601))
        XCTAssertTrue(bridge.haveAsync(602))
        XCTAssertFalse(bridge.haveAsync(999), "an unregistered async id is not resolvable")
        // The SYNC registry is independent — an async id is not in `have`.
        XCTAssertFalse(bridge.have(601), "an async-only id is not in the sync registry")
    }

    /// `callAsync` runs the registered async thunk to completion and returns the exact value.
    func testCallAsyncReturnsValue() async {
        let bridge = makeAsyncBridge()
        let r = await bridge.callAsync(601, argsBlob: TLVCodec.encodeArgs([.string("gold")]))
        XCTAssertEqual(r, .i64(1299), "the async thunk awaits the real native symbol value")
    }

    /// THE CONTINUATION WIRING (the load-bearing async proof). The broker captures a pending
    /// async call (as the `patch_host.call_async` import would), then — driven by the pump's
    /// stall handler — runs the async thunk, encodes the TLV result blob, and resumes via the
    /// injected write/invoke closures. We assert the RIGHT result blob is delivered to the
    /// RIGHT token (exactly the bytes `patch_resolve_hostcall(token, ptr, len)` would carry).
    func testAsyncBrokerResolvesContinuation() throws {
        let bridge = makeAsyncBridge()
        let broker = PatchAsyncCallBroker(bridge: bridge)

        // (1) The guest suspended on token 7 awaiting Store.priceCents("gold").
        broker.enqueue(token: 7, symbolId: 601, argsBlob: TLVCodec.encodeArgs([.string("gold")]))
        XCTAssertTrue(broker.hasPending)

        // (2) The pump stalls → resolvePending. Inject the two guest-memory primitives the
        // real SDK supplies (writeBuffer + the patch_resolve_hostcall invoke). We capture
        // what was delivered instead of touching real WASM memory.
        var deliveredToken: Int32?
        var deliveredBlob: [UInt8] = []
        // A trivial fake "guest memory": writeBlob stashes the bytes + returns a fake ptr.
        var fakeMemory: [UInt8] = []
        let progressed = try broker.resolvePending(
            writeBlob: { bytes in
                let ptr = UInt32(fakeMemory.count)
                fakeMemory.append(contentsOf: bytes)
                return (ptr, UInt32(bytes.count))
            },
            invokeResolve: { token, ptr, len in
                deliveredToken = token
                deliveredBlob = Array(fakeMemory[Int(ptr)..<Int(ptr) + Int(len)])
            })

        XCTAssertTrue(progressed, "resolving an owed call makes progress")
        XCTAssertFalse(broker.hasPending, "the owed call was drained")
        XCTAssertEqual(deliveredToken, 7, "the result is resumed against the suspended token")
        // (3) The delivered blob decodes to the exact native value — the guest would read this.
        let value = try TLVCodec.decodeResult(deliveredBlob)
        XCTAssertEqual(value, .i64(1299), "the resumed continuation carries the value-exact result")
    }

    /// The async-throwing path composes: a successful `async throws` thunk delivers the value;
    /// a throwing one delivers a tagged `.error` (DEMOTE-SAFE), both through the broker.
    func testAsyncThrowingBrokerPaths() throws {
        let bridge = makeAsyncBridge()

        func resolveOne(token: Int32, symbolId: Int32, args: [TLVValue]) throws -> TLVValue {
            let broker = PatchAsyncCallBroker(bridge: bridge)
            broker.enqueue(token: token, symbolId: symbolId, argsBlob: TLVCodec.encodeArgs(args))
            var blob: [UInt8] = []
            var mem: [UInt8] = []
            _ = try broker.resolvePending(
                writeBlob: { bytes in let p = UInt32(mem.count); mem.append(contentsOf: bytes); return (p, UInt32(bytes.count)) },
                invokeResolve: { _, ptr, len in blob = Array(mem[Int(ptr)..<Int(ptr) + Int(len)]) })
            return try TLVCodec.decodeResult(blob)
        }

        // Success: Store.load("k") → "loaded:k".
        XCTAssertEqual(try resolveOne(token: 1, symbolId: 602, args: [.string("k")]),
                       .string("loaded:k"))
        // Throw: Store.load("missing") throws → tagged .error.
        guard case .error = try resolveOne(token: 2, symbolId: 602, args: [.string("missing")]) else {
            return XCTFail("an async-throwing native error must surface as a tagged .error")
        }
    }

    /// DEMOTE-SAFE: an UNKNOWN async id resolves to a tagged `.error` (the guest then demotes),
    /// never a crash. The broker still resumes the suspended token with that `.error` blob.
    func testUnknownAsyncIdDemotes() throws {
        let bridge = makeAsyncBridge()
        let broker = PatchAsyncCallBroker(bridge: bridge)
        broker.enqueue(token: 9, symbolId: 999 /* unregistered */, argsBlob: TLVCodec.encodeArgs([]))
        var blob: [UInt8] = []
        var mem: [UInt8] = []
        var resumedToken: Int32?
        _ = try broker.resolvePending(
            writeBlob: { bytes in let p = UInt32(mem.count); mem.append(contentsOf: bytes); return (p, UInt32(bytes.count)) },
            invokeResolve: { token, ptr, len in resumedToken = token; blob = Array(mem[Int(ptr)..<Int(ptr) + Int(len)]) })
        XCTAssertEqual(resumedToken, 9, "even an unknown async id resumes the suspended token (so the guest never hangs)")
        guard case .error = try TLVCodec.decodeResult(blob) else {
            return XCTFail("an unknown async id must resume with a tagged .error → demote")
        }
    }

    /// DEMOTE-SAFE: a HUNG async thunk is bounded by the resolve timeout → tagged `.error`
    /// (a stuck native symbol can never deadlock the pump). Uses a tiny timeout so the test
    /// is fast.
    func testHungAsyncThunkTimesOutToError() throws {
        let bridge = PatchHostBridge()
        bridge.registerAsync(id: 700, signature: "hang") { _, _ in
            // Never completes within the timeout.
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return .i64(1)
        }
        let broker = PatchAsyncCallBroker(bridge: bridge)
        broker.enqueue(token: 1, symbolId: 700, argsBlob: TLVCodec.encodeArgs([]))
        var blob: [UInt8] = []
        var mem: [UInt8] = []
        _ = try broker.resolvePending(
            timeout: 0.2,
            writeBlob: { bytes in let p = UInt32(mem.count); mem.append(contentsOf: bytes); return (p, UInt32(bytes.count)) },
            invokeResolve: { _, ptr, len in blob = Array(mem[Int(ptr)..<Int(ptr) + Int(len)]) })
        guard case .error(let m) = try TLVCodec.decodeResult(blob) else {
            return XCTFail("a hung async thunk must time out to a tagged .error")
        }
        XCTAssertTrue(m.contains("timed out"), "the .error names the timeout: \(m)")
    }

    /// `teardownAsync()` drops the async registry (a module epoch can't leak its async thunks).
    func testTeardownAsyncClearsRegistry() {
        let bridge = makeAsyncBridge()
        XCTAssertTrue(bridge.haveAsync(601))
        bridge.teardownAsync()
        XCTAssertFalse(bridge.haveAsync(601), "teardownAsync drops every async thunk")
    }

    // =======================================================================
    // MARK: - The GLUE adapter (GenericHostBridge.asyncResolve)
    // =======================================================================

    /// `GenericHostBridge.withAsyncBroker(_:)` attaches the broker, and `asyncResolve`
    /// forwards to it. Proves the glue surface the SDK pump wires to (the same write/invoke
    /// closures the WasmKit path supplies via `runtime.writeBuffer` / the resolve invoke).
    func testGenericHostBridgeAsyncResolveForwards() throws {
        let bridge = makeAsyncBridge()
        let broker = PatchAsyncCallBroker(bridge: bridge)
        let glue = GenericHostBridge(bridge: bridge).withAsyncBroker(broker)
        XCTAssertNotNil(glue.asyncBroker)

        broker.enqueue(token: 3, symbolId: 601, argsBlob: TLVCodec.encodeArgs([.string("silver")]))
        var blob: [UInt8] = []
        var mem: [UInt8] = []
        let progressed = try glue.asyncResolve(
            writeBlob: { bytes in let p = UInt32(mem.count); mem.append(contentsOf: bytes); return (p, UInt32(bytes.count)) },
            invokeResolve: { _, ptr, len in blob = Array(mem[Int(ptr)..<Int(ptr) + Int(len)]) })
        XCTAssertTrue(progressed)
        XCTAssertEqual(try TLVCodec.decodeResult(blob), .i64(499), "silver → 499 cents, value-exact")

        // No broker wired → asyncResolve is a no-op (false), composes with other resolvers.
        let bare = GenericHostBridge(bridge: bridge)
        XCTAssertFalse(try bare.asyncResolve(writeBlob: { _ in (0, 0) }, invokeResolve: { _, _, _ in }),
                       "no async broker → no progress (composes with HTTP/bare-async resolvers)")
    }
}
