import XCTest
@testable import PatchSDK
import PatchViewIR
#if canImport(SwiftUI)
import SwiftUI
import PatchRender
@testable import PatchSwiftUI
#endif

/// END-TO-END through the SDK against a REAL engine-built module: the `Banner`
/// view lowered by the production PATCH_SWIFTUI pipeline into a PMOD that exports
/// `view_body__Banner` + `patch_view_manifest`. Proves the out-of-the-box
/// patching path: the SDK reads the manifest, `thunkBody` routes a thunked view
/// to the lowered body, and the marshalled instance inputs reach the WASM tree —
/// with NO `PatchView` anywhere.
#if canImport(SwiftUI)
final class AutoPatchIntegrationTests: XCTestCase {

    private func bannerModule() throws -> [UInt8] {
        guard let url = Bundle.module.url(forResource: "AutoPatchBanner", withExtension: "wasm") else {
            throw XCTSkip("AutoPatchBanner.wasm fixture missing")
        }
        return [UInt8](try Data(contentsOf: url))
    }

    /// All text strings in a ViewNode subtree (for content assertions).
    private func texts(_ n: ViewNode) -> [String] {
        var out: [String] = []
        if case .text(let s) = n.kind { out.append(s) }
        for c in n.childNodes { out.append(contentsOf: texts(c)) }
        return out
    }

    // MARK: - Engine output (no singleton)

    func testModuleExportsManifestAndLoweredBody() throws {
        let patch = Patch()
        try patch.activate(bytes: try bannerModule())
        XCTAssertTrue(patch.hasFunction("patch_view_manifest"), "engine did not emit the view manifest export")
        XCTAssertTrue(patch.hasFunction("view_body__Banner"))
    }

    func testManifestDescribesBannerAsThunkSafe() throws {
        let patch = Patch()
        try patch.activate(bytes: try bannerModule())
        let bytes = try patch.callPacked("patch_view_manifest", [])
        let manifest = try JSONDecoder().decode(PatchViewManifest.self, from: Data(bytes))
        // The fixture is a prebuilt module; assert the host SUPPORTS its stamped
        // schema (the real runtime contract — minSupportedVersion…version) rather
        // than exact equality, so an older-engine module still validates after a
        // host-only schema bump.
        XCTAssertTrue(PatchViewIRSchema.isSupported(manifest.schemaVersion),
                      "manifest schema v\(manifest.schemaVersion) unsupported by host v\(PatchViewIRSchema.version)")
        guard let banner = manifest.views.first(where: { $0.type == "Banner" }) else {
            return XCTFail("manifest has no Banner entry: \(manifest.views.map(\.type))")
        }
        XCTAssertTrue(banner.thunkSafe, "Banner lowered 100% — should be thunkSafe")
        XCTAssertEqual(banner.export, "view_body__Banner")
        XCTAssertNil(banner.dispatch, "Banner is non-interactive — no dispatch export")
    }

    func testLoweredBodyRendersMarshalledInput() throws {
        let patch = Patch()
        try patch.activate(bytes: try bannerModule())
        // The host marshals the live instance's `title` into the flat inputs JSON;
        // the lowered WASM body reads it and builds the tree.
        let tree = try patch.viewBody(state: #"{"title":"Patched!"}"#, export: "view_body__Banner")
        let allText = texts(tree)
        XCTAssertTrue(allText.contains("Patched!"), "marshalled title not in tree: \(allText)")
        XCTAssertTrue(allText.contains("Welcome"), "static text missing: \(allText)")
    }

    // MARK: - The thunkBody glue (singleton — reset after)

    @MainActor
    func testThunkBodyRoutesThunkSafeViewAndIgnoresUnknown() throws {
        // A stand-in for the developer's `Banner` view; the thunk passes `self` and
        // the registry marshals its stored properties (here `title`) into the guest.
        struct BannerInstance { var title = "FromInstance" }

        Patch.configure(.init(appKey: "test-autopatch", apiBaseURL: nil))
        defer { Patch.shared.deactivate() }
        try Patch.shared.activate(bytes: try bannerModule())

        // A thunkSafe view in the manifest → a PatchedBodyHost is returned.
        let host = Patch.shared.thunkBody(typeName: "Banner", instance: BannerInstance())
        XCTAssertNotNil(host, "thunkBody should route the thunkSafe Banner view")

        // A view NOT in the manifest → nil (the thunk falls through to native body).
        XCTAssertNil(Patch.shared.thunkBody(typeName: "NotAView", instance: BannerInstance()))
    }

    @MainActor
    func testThunkBodyReturnsNilWithNoModule() throws {
        // Fresh registry state is hard to guarantee across tests, but with no active
        // module + no manifest, an arbitrary type must not route.
        Patch.configure(.init(appKey: "test-autopatch-2", apiBaseURL: nil))
        Patch.shared.deactivate()
        XCTAssertNil(Patch.shared.thunkBody(typeName: "Banner", instance: 0))
    }

    // MARK: - MIXED views (a partially-lowerable body with native leaves)

    /// Loads a REAL engine-built mixed module (`MixedScreen` = lowered Text +
    /// native `Card()` + `Color(red:)` leaves). Read by absolute path so CI isn't
    /// bloated by the multi-MB Foundation guest; skips when absent.
    private func mixedModule() throws -> [UInt8] {
        let path = "/tmp/patch-e2e/mixed/module.swiftui.wasm"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("mixed module fixture not present (build /tmp/patch-e2e/mixed)")
        }
        return [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
    }

    func testMixedViewManifestMarksRoutableWithSlotableLeaves() throws {
        let patch = Patch()
        // The mixed guest lowers at the Foundation (T2) tier → register the standard
        // patch_host.* bridges (decimal_op/json/now/…) so it instantiates.
        patch.bridges.registerDefaults()
        try patch.activate(bytes: try mixedModule())
        let bytes = try patch.callPacked("patch_view_manifest", [])
        let manifest = try JSONDecoder().decode(PatchViewManifest.self, from: Data(bytes))
        guard let mixed = manifest.views.first(where: { $0.type == "MixedScreen" }) else {
            return XCTFail("no MixedScreen entry: \(manifest.views.map(\.type))")
        }
        // Card() + Color(red:) are slotable native leaves → the view is still routable.
        XCTAssertTrue(mixed.thunkSafe, "mixed view with slotable leaves should be thunkSafe")
    }

    func testMixedViewBodyTreeHasLoweredPartsAndOpaqueLeaves() throws {
        let patch = Patch()
        // The mixed guest lowers at the Foundation (T2) tier → register the standard
        // patch_host.* bridges (decimal_op/json/now/…) so it instantiates.
        patch.bridges.registerDefaults()
        try patch.activate(bytes: try mixedModule())
        let tree = try patch.viewBody(state: "{}", export: "view_body__MixedScreen")
        // Lowered parts ride WASM (the Text nodes).
        XCTAssertTrue(texts(tree).contains("Patched title"), "lowered Text missing: \(texts(tree))")
        // The native leaves are opaque slots carrying content-stable ids.
        let opaqueIDs = PatchedBodyHost.collectOpaqueIDs(tree)
        XCTAssertFalse(opaqueIDs.isEmpty, "expected opaque leaves for Card()/Color(red:)")
        XCTAssertTrue(opaqueIDs.allSatisfy { $0.hasPrefix("op_") }, "leaf ids: \(opaqueIDs)")
    }

    /// `PatchedBodyHost.collectTokenIDs` finds EVERY design-system token id in a tree —
    /// a `.hostToken` color directly on a modifier, a `.fontToken`, and a token nested
    /// in an `IRShapeStyle.color` of a `.fill`. These are the ids the thunk's
    /// `__patchTokens()` must cover (an uncovered one demotes the whole view).
    func testCollectTokenIDsFindsColorAndFontTokens() throws {
        let tree = N.vstack([
            N.text("a").foregroundColor(.hostToken("ct_fg")).fontToken("ft_a"),
            N.shape(.capsule).fill(.color(.hostToken("ct_fill"))),
            N.text("b").background(.hostToken("ct_bg")).tint(.hostToken("ct_tint"))
        ])
        let ids = Set(PatchedBodyHost.collectTokenIDs(tree))
        XCTAssertEqual(ids, ["ct_fg", "ft_a", "ct_fill", "ct_bg", "ct_tint"],
                       "every color + font token id (incl. nested-in-fill) must be collected")
    }
}
#endif
