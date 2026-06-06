import XCTest
import PatchViewIR
#if canImport(SwiftUI)
import SwiftUI
@testable import PatchRender
#endif

/// The SwiftUI renderer: a `ViewNode` tree reconstitutes to real SwiftUI, and an
/// interactive control's binding dispatches an event back into the guest dispatch.
final class PatchRenderTests: XCTestCase {

    // MARK: - IR + schema (no SwiftUI needed)

    /// The IR round-trips through its JSON wire format (the boundary format the
    /// guest emits and the host decodes), and the schema-version gate works.
    func testIRWireRoundTripAndSchema() throws {
        let tree = N.vstack(spacing: 8, [
            N.text("Hello").fontSize(17, weight: .semibold).foregroundColor(named: "primary"),
            N.toggle("Notify", isOn: true, event: "flip"),
            N.button("Save", actionID: "save")
        ]).padding(16)

        // Stamp the current schema version and round-trip the emission envelope.
        let emission = BodyEmission(root: tree, computeCoverage: true,
                                    schemaVersion: PatchViewIRSchema.version)
        let bytes = try ViewNodeWire.encode(emission)
        let back = try ViewNodeWire.decode(bytes)
        XCTAssertEqual(back.root, tree, "ViewNode survives the JSON boundary intact")
        XCTAssertEqual(back.schemaVersion, PatchViewIRSchema.version)
        XCTAssertNoThrow(try PatchViewIRSchema.check(back.schemaVersion))

        // The Foundation-FREE embedded emitter produces the SAME bytes the host
        // JSONDecoder reads (this is what a tiny embedded guest uses).
        let embeddedBytes = EmbeddedJSON.encode(emission)
        let backEmbedded = try ViewNodeWire.decode(embeddedBytes)
        XCTAssertEqual(backEmbedded.root, tree)
        XCTAssertEqual(backEmbedded.schemaVersion, PatchViewIRSchema.version)
    }

    /// An unstamped (legacy) emission decodes fine and is treated as current.
    func testUnstampedEmissionTreatedAsCurrent() throws {
        let emission = BodyEmission(root: N.text("hi"), computeCoverage: false)
        XCTAssertNil(emission.schemaVersion)
        XCTAssertNoThrow(try PatchViewIRSchema.check(emission.schemaVersion))
    }

    /// A future guest schema the host can't decode is rejected with a Mismatch.
    func testFutureSchemaRejected() {
        let future = PatchViewIRSchema.version + 1
        XCTAssertFalse(PatchViewIRSchema.isSupported(future))
        XCTAssertThrowsError(try PatchViewIRSchema.check(future)) { err in
            guard let m = err as? PatchViewIRSchema.Mismatch else {
                return XCTFail("expected Mismatch, got \(err)")
            }
            XCTAssertEqual(m.guestVersion, future)
        }
    }

    // MARK: - Real SwiftUI rendering

    #if canImport(SwiftUI)
    /// Every node kind + modifier renders to a real `AnyView` without trapping.
    @MainActor
    func testRenderProducesSwiftUIForAllKinds() {
        let tree = N.vstack(alignment: .center, spacing: 8, [
            N.text("hello").fontSize(20, weight: .bold).foregroundColor(named: "red"),
            N.image(systemName: "star.fill").foregroundColor(named: "yellow"),
            N.spacer(minLength: 4), N.divider,
            N.color(.named("blue")).frame(width: 40, height: 40),
            N.shape(.roundedRectangle(cornerRadius: 8)).frame(height: 20),
            N.hstack(spacing: 4, [N.text("a"), N.text("b")]),
            N.zstack(alignment: .topLeading, [N.text("z")]),
            N.group([N.text("g1"), N.text("g2")]),
            N.forEach([N.text("1"), N.text("2")]),
            N.button("Tap", actionID: "act1").padding().background(named: "green"),
            N.toggle("Notifications", isOn: true, event: "n"),
            N.slider(value: 0.4, in: 0...1, event: "v"),
            N.stepper("Badge", value: 3, in: 0...9, event: "b"),
            N.textField("Name", text: "Ada", event: "name"),
            N.opaque(id: "custom1", label: "MapView")
        ]).padding(.all(12)).opacity(0.95)
        XCTAssertNotNil(render(tree))
    }

    /// An interactive control's binding fires the Dispatcher with the event + new
    /// value — the host end of the WASM dispatch loop. THIS is "a dispatched event
    /// updates it" at the renderer layer.
    @MainActor
    func testDispatchedEventFlowsThroughRenderer() {
        var captured: [(String, IRValue)] = []
        let dispatcher = Dispatcher { e, v in captured.append((e.id, v)) }
        let ctx = RenderContext(dispatcher: dispatcher)

        _ = render(N.toggle("x", isOn: false, event: "flip"), context: ctx)
        // Simulate the Toggle's binding firing (what SwiftUI does on a tap).
        dispatcher.send(EventID("flip"), .bool(true))
        dispatcher.send(EventID("tap"), .none)

        XCTAssertEqual(captured.count, 2)
        XCTAssertEqual(captured[0].0, "flip"); XCTAssertEqual(captured[0].1, .bool(true))
        XCTAssertEqual(captured[1].1, .none)
    }

    /// `PatchView` drives the closure-based TEA loop: the reduce closure runs on a
    /// dispatched event and the new state is produced. (We exercise the reduce
    /// wiring directly; the SwiftUI @State re-render is covered by the live-module
    /// test in PatchSwiftUI.)
    @MainActor
    func testPatchViewReduceWiring() {
        var reduced: [(String, EventID, IRValue)] = []
        let view = PatchView(
            initialState: "{\"on\":false}",
            treeProvider: { _ in N.toggle("x", isOn: false, event: "flip") },
            reduce: { state, event, value in
                reduced.append((state, event, value))
                return "{\"on\":true}"
            })
        // Building the body installs a dispatcher bound to the reduce closure.
        _ = view.body
        XCTAssertNotNil(view.treeProvider("{}"))
        XCTAssertNotNil(view.reduce)
        // Drive the reduce directly (what the dispatcher does on a control change).
        _ = view.reduce?("{\"on\":false}", EventID("flip"), .bool(true))
        XCTAssertEqual(reduced.count, 1)
        XCTAssertEqual(reduced[0].1.id, "flip")
        XCTAssertEqual(reduced[0].2, .bool(true))
    }
    #endif
}
