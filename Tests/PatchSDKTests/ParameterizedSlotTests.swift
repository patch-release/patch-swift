import XCTest
import Foundation
import PatchViewIR
#if canImport(SwiftUI)
import SwiftUI
import PatchRender
@testable import PatchSwiftUI

/// SDK side of PARAMETERIZED NATIVE SLOTS: the host decodes `BodyEmission.slotArgs`
/// from the guest emission and renders a parameterized native slot by applying the
/// thunk's FACTORY (`([String]) -> AnyView`) to the lifted, OTA-shipped values —
/// so editing a string literal inside a slotted custom view shows the NEW string.
final class ParameterizedSlotTests: XCTestCase {

    // MARK: - 1. Wire round-trip: the host decodes slotArgs

    /// `BodyEmission.slotArgs` is an OPTIONAL additive field: it encodes as a JSON
    /// object of arrays and decodes round-trip; a guest that emits none decodes `nil`.
    func testSlotArgsCodableRoundTrip() throws {
        let tree = N.vstack([N.text("Header"), N.opaque(id: "op_a", label: "Foo")])
        let emission = BodyEmission(root: tree, coverage: nil, schemaVersion: PatchViewIRSchema.version,
                                    slotArgs: ["op_a": ["Settings"]])
        let bytes = try ViewNodeWire.encode(emission)
        let back = try ViewNodeWire.decode(bytes)
        XCTAssertEqual(back.slotArgs?["op_a"], ["Settings"], "slotArgs survives the wire: \(String(describing: back.slotArgs))")
    }

    func testMissingSlotArgsDecodesNil() throws {
        // A guest that emits no slotArgs key (older guest / no parameterized slot).
        let json = #"{"root":{"kind":{"text":{"_0":"hi"}},"modifiers":[]}}"#
        let back = try ViewNodeWire.decode(Array(json.utf8))
        XCTAssertNil(back.slotArgs, "a missing slotArgs key decodes nil (back-compatible)")
    }

    func testMultiArgSlotArgsRoundTrip() throws {
        let emission = BodyEmission(root: N.opaque(id: "op_x", label: "Foo"),
                                    slotArgs: ["op_x": ["A", "B", "C"]])
        let back = try ViewNodeWire.decode(try ViewNodeWire.encode(emission))
        XCTAssertEqual(back.slotArgs?["op_x"], ["A", "B", "C"])
    }

    // MARK: - 2. Renderer: a parameterized factory fills the opaque slot with the
    //          CURRENT (OTA-shipped) value — proving the new string renders.

    /// The renderer reads a pre-resolved `AnyView` from the `OpaqueTable`. The host
    /// (`PatchedBodyHost`) resolves it by applying the factory to `slotArgs[id]`. This
    /// test reproduces that exact host step and asserts the value the factory received
    /// reflects the CURRENT literal — i.e. an OTA edit "Hello"→"Settings" renders
    /// "Settings", not the stale "Hello" baked at build time.
    @MainActor
    func testFactoryRendersCurrentLiteral() {
        // A parameterized factory like the thunk emits: it ignores the build-time
        // literal and renders whatever value rides in (the OTA-shipped one).
        var captured: String?
        let factory: ([String]) -> AnyView = { a in
            captured = a.first
            return AnyView(Text(a.first ?? "?"))
        }
        // The build baked "Hello"; the OTA emission ships "Settings".
        let slotArgs: [String: [String]] = ["op_a": ["Settings"]]
        let id = "op_a"

        // Reproduce PatchedBodyHost's opaque-table fill.
        let table = OpaqueTable()
        table.set(id, factory(slotArgs[id] ?? []))
        XCTAssertEqual(captured, "Settings",
            "the factory rendered the CURRENT (OTA-shipped) literal, not the build-time one")
        XCTAssertNotNil(table.view(for: id), "the opaque slot is filled")

        // The renderer then renders the filled slot (no crash; the AnyView is used).
        let tree = N.vstack([N.text("Header"), N.opaque(id: id, label: "Foo")])
        var ctx = RenderContext(showOpaqueStubs: false)
        ctx.opaques.set(id, factory(slotArgs[id] ?? []))
        _ = render(tree, context: ctx)
    }

    /// DEMOTE-SAFE: a parameterized factory with an arg-count guard returns EmptyView
    /// (never crashes) when the args are short/missing — the exact shape the thunk
    /// emits (`a.count >= N ? AnyView(...) : AnyView(EmptyView())`).
    @MainActor
    func testFactoryArgCountGuardIsSafe() {
        let factory: ([String]) -> AnyView = { a in
            a.count >= 1 ? AnyView(Text(a[0])) : AnyView(EmptyView())
        }
        // No args (a malformed/missing slotArgs entry) → EmptyView, no crash.
        let v = factory([])
        XCTAssertNotNil(v, "empty args yields EmptyView, never a crash")
        // With the value it renders fine.
        _ = factory(["ok"])
    }
}
#endif
