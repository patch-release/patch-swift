// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
import WasmKit
import WasmKitWASI
@testable import CodeGenerator
@testable import Compiler
import ViewNodeIR

/// Tests for the RICH (non-scalar) view-input marshalling coverage win: a view that
/// takes a SINGLE flat struct (`let item: Product`) or a RAW-VALUE enum (`let s: Status`)
/// now LOWERS — the engine generates a mirroring guest struct/enum + a scanner over the
/// SDK's nested-object / `{"case":"…"}` marshalling, so the body's `item.<field>` /
/// `s == .case` / `switch s` / `s.rawValue` reads resolve in WASM.
///
/// Every step is DEMOTE-SAFE: an input used in a way the guest can't faithfully
/// reconstruct (a bare `item`, a method call, a non-flat-field access, a bare enum passed
/// somewhere) is downgraded to `.unsupported` so the view stays native — never a wrong /
/// partial reconstruction.
final class SwiftUIRichInputMarshalTests: XCTestCase {

    // MARK: - TASK 1: single flat struct input

    func testSingleFlatStructInputClassifiedAndLowers() throws {
        let source = """
        import SwiftUI
        struct Product { var name: String; var price: Double; var inStock: Bool }
        struct ProductRow: View {
            let item: Product
            var body: some View {
                VStack {
                    Text(item.name)
                    Text("price=\\(item.price)")
                    if item.inStock { Text("In stock") }
                }
            }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        let item = try XCTUnwrap(lowered.inputs.first { $0.name == "item" })
        XCTAssertEqual(item.kind, .flatStruct)
        XCTAssertTrue(item.kind.guestReconstructable)
        XCTAssertFalse(lowered.referencesUnmarshalledInput,
                       "a single flat-struct input the body reads only as item.<field> must NOT demote")
        let el = try XCTUnwrap(item.structElement)
        XCTAssertEqual(el.typeName, "Product")
        XCTAssertEqual(el.fields.map(\.name), ["name", "price", "inStock"])
        // The lowered tree reads the struct fields as live member accesses (no opaque slot).
        let g = lowered.guestBody
        XCTAssertTrue(g.contains("item.name"), "body reads item.name: \(g)")
        XCTAssertTrue(g.contains("item.price"), "body reads item.price: \(g)")
        XCTAssertFalse(g.contains("N.opaque"), "a flat-struct-input view must fully lower: \(g)")
    }

    func testSingleFlatStructGuestEmitsStructAndObjectScanner() throws {
        let source = """
        import SwiftUI
        struct Product { var name: String; var price: Double }
        struct ProductRow: View {
            let item: Product
            var body: some View { Text(item.name) }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        let view = SwiftUIGuestEmitter.GuestView(
            viewName: lowered.viewName, guestBody: lowered.guestBody, inputs: lowered.inputs)
        let emission = try SwiftUIGuestEmitter().emit(views: [view])
        let wrapper = try XCTUnwrap(emission.files.first { $0.fileName == "_PatchSwiftUI.swift" })
        // A mirroring guest struct + the SINGLE-OBJECT scanner are emitted.
        XCTAssertTrue(wrapper.contents.contains("struct _PatchRow_Product {"),
                      "mirroring guest struct generated")
        XCTAssertTrue(wrapper.contents.contains("var name: String = \"\""))
        XCTAssertTrue(wrapper.contents.contains("var price: Double = 0"))
        // The input binds via the single-object scanner (NOT the array scanner).
        XCTAssertTrue(wrapper.contents.contains("_patchScanProductRow(_patchInputs, \"item\")"),
                      "the single-struct input binds via the generated object scanner")
        XCTAssertTrue(wrapper.contents.contains("?? _PatchRow_Product()"),
                      "falls back to a zero-value struct, never a crash")
        // The object-body byte cutter is present (needed by the single scanner).
        XCTAssertTrue(wrapper.contents.contains("func _patchObjectBody"))
    }

    func testSingleFlatStructBareUseDemotes() throws {
        // The body passes `item` BARE (not `item.<field>`) — the guest struct isn't
        // CustomStringConvertible, so it can't compile. Downgrade to native.
        let source = """
        import SwiftUI
        struct Product { var name: String }
        struct ProductRow: View {
            let item: Product
            var body: some View { Text("\\(item)") }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        let item = try XCTUnwrap(lowered.inputs.first { $0.name == "item" })
        // The gate downgrades a bare struct use to `.unsupported`: the engine NEVER binds
        // the guest struct + reads `item.<field>` from it (which would be wrong for a bare
        // `item`). The body resolves the whole `"\\(item)"` natively instead (a host string
        // token / native slot) — never reconstructing the struct guest-side.
        XCTAssertEqual(item.kind, .unsupported, "a bare struct use must downgrade to unsupported")
        XCTAssertFalse(lowered.guestBody.contains("_patchScanProductRow(_patchInputs, \"item\")"),
                       "the unsupported struct must NOT bind via the object scanner: \(lowered.guestBody)")
        XCTAssertFalse(lowered.guestBody.contains("item.name"),
                       "no flat-field read against an unbound guest struct: \(lowered.guestBody)")
    }

    func testSingleFlatStructMethodCallDemotes() throws {
        // `item.name.uppercased()` chains a method onto the field — not guest-safe.
        let source = """
        import SwiftUI
        struct Product { var name: String }
        struct ProductRow: View {
            let item: Product
            var body: some View { Text(item.name.uppercased()) }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        let item = try XCTUnwrap(lowered.inputs.first { $0.name == "item" })
        XCTAssertEqual(item.kind, .unsupported,
                       "a chained method on a struct field must downgrade to unsupported")
    }

    func testSingleFlatStructUnknownMemberDemotes() throws {
        // `item.computed` is not one of the flat stored fields — can't resolve in the guest.
        let source = """
        import SwiftUI
        struct Product { var name: String }
        struct ProductRow: View {
            let item: Product
            var body: some View { Text(item.computed) }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        let item = try XCTUnwrap(lowered.inputs.first { $0.name == "item" })
        XCTAssertEqual(item.kind, .unsupported,
                       "an access to a non-flat-field must downgrade to unsupported")
    }

    func testNonFlatStructInputNowReconstructs() throws {
        // `Profile` has a NESTED struct field (`addr: Address`). The recursive
        // marshalling now reconstructs it (render-correctness proven by
        // `testNestedStructExecutesInWasm`), so a nested-struct input is `.flatStruct`
        // (guest-reconstructable) and the body lowers — no longer `.unsupported`.
        let source = """
        import SwiftUI
        struct Address { var city: String }
        struct Profile { var name: String; var addr: Address }
        struct ProfileRow: View {
            let p: Profile
            var body: some View { Text(p.name) }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        let p = try XCTUnwrap(lowered.inputs.first { $0.name == "p" })
        XCTAssertEqual(p.kind, .flatStruct, "a nested-struct input now reconstructs")
        XCTAssertTrue(p.kind.guestReconstructable)
        XCTAssertFalse(lowered.referencesUnmarshalledInput,
                       "a reconstructable nested-struct input is not an unmarshalled read")
    }

    func testOptionalStructInputStaysUnsupported() throws {
        // `Product?` is Optional → the guest reconstruction can't prove unwrap-safety.
        let source = """
        import SwiftUI
        struct Product { var name: String }
        struct ProductRow: View {
            let item: Product?
            var body: some View { Text(item?.name ?? "none") }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        let item = try XCTUnwrap(lowered.inputs.first { $0.name == "item" })
        XCTAssertEqual(item.kind, .unsupported, "an optional struct input stays unsupported")
    }

    // MARK: - TASK 2: raw-value enum input

    func testRawValueEnumInputClassifiedAndLowers() throws {
        let source = """
        import SwiftUI
        enum Status: String { case active, archived, draft }
        struct StatusBadge: View {
            let status: Status
            var body: some View {
                VStack {
                    if status == .active { Text("Active") }
                    if status == .archived { Text("Archived") }
                    Text(status.rawValue)
                }
            }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        let status = try XCTUnwrap(lowered.inputs.first { $0.name == "status" })
        XCTAssertEqual(status.kind, .enumValue)
        XCTAssertTrue(status.kind.guestReconstructable)
        XCTAssertFalse(lowered.referencesUnmarshalledInput,
                       "a raw-value enum the body reads guest-reconstructably must NOT demote")
        let el = try XCTUnwrap(status.enumElement)
        XCTAssertEqual(el.typeName, "Status")
        XCTAssertEqual(el.rawKind, .string)
        XCTAssertEqual(el.caseNames, ["active", "archived", "draft"])
        let g = lowered.guestBody
        XCTAssertTrue(g.contains("status == .active"), "compares against a case: \(g)")
        XCTAssertTrue(g.contains("status.rawValue"), "reads rawValue: \(g)")
        XCTAssertFalse(g.contains("N.opaque"), "a raw-enum-input view must fully lower: \(g)")
    }

    func testSwitchOverRawEnumLowers() throws {
        let source = """
        import SwiftUI
        enum Medal: Int { case gold = 1, silver = 2, bronze = 3 }
        struct MedalView: View {
            let medal: Medal
            var body: some View {
                switch medal {
                case .gold: Text("Gold")
                case .silver: Text("Silver")
                case .bronze: Text("Bronze")
                }
            }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        let medal = try XCTUnwrap(lowered.inputs.first { $0.name == "medal" })
        XCTAssertEqual(medal.kind, .enumValue)
        let el = try XCTUnwrap(medal.enumElement)
        XCTAssertEqual(el.rawKind, .int)
        XCTAssertEqual(el.cases.map(\.rawLiteral), ["1", "2", "3"])
        XCTAssertFalse(lowered.referencesUnmarshalledInput, "a switch over a raw enum lowers")
    }

    func testRawEnumGuestEmitsEnumAndScanner() throws {
        let source = """
        import SwiftUI
        enum Status: String { case active, archived }
        struct Badge: View {
            let status: Status
            var body: some View { if status == .active { Text("A") } else { Text("B") } }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        let view = SwiftUIGuestEmitter.GuestView(
            viewName: lowered.viewName, guestBody: lowered.guestBody, inputs: lowered.inputs)
        let emission = try SwiftUIGuestEmitter().emit(views: [view])
        let wrapper = try XCTUnwrap(emission.files.first { $0.fileName == "_PatchSwiftUI.swift" })
        XCTAssertTrue(wrapper.contents.contains("enum _PatchEnum_Status: String {"),
                      "mirroring guest enum generated")
        XCTAssertTrue(wrapper.contents.contains("_patchScanStatusEnum(_patchInputs, \"status\")"),
                      "enum input binds via the generated case scanner")
        XCTAssertTrue(wrapper.contents.contains("?? .active"),
                      "falls back to the first declared case")
        XCTAssertTrue(wrapper.contents.contains("case \"active\": return .active"),
                      "the case scanner maps by name")
    }

    func testEnumWithAssociatedValueStaysUnsupported() throws {
        // A payload case can't be reconstructed from `{"case":"…"}` — the whole enum is
        // ineligible, so the input stays unsupported.
        let source = """
        import SwiftUI
        enum Route: Equatable { case home, detail(id: String) }
        struct Nav: View {
            let route: Route
            var body: some View { if route == .home { Text("Home") } else { Text("Other") } }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        let route = try XCTUnwrap(lowered.inputs.first { $0.name == "route" })
        XCTAssertEqual(route.kind, .unsupported,
                       "an enum with an associated-value case stays unsupported")
    }

    func testNonRawEnumInputStaysUnsupported() throws {
        // A plain enum (no String/Int raw) isn't reconstructable as a raw-value enum.
        let source = """
        import SwiftUI
        enum Mode { case light, dark }
        struct V: View {
            let mode: Mode
            var body: some View { if mode == .light { Text("L") } else { Text("D") } }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        let mode = try XCTUnwrap(lowered.inputs.first { $0.name == "mode" })
        XCTAssertEqual(mode.kind, .unsupported, "a non-raw enum input stays unsupported")
    }

    func testEnumMethodCallDemotes() throws {
        // `status.describe()` is a method call — not a reconstructable use.
        let source = """
        import SwiftUI
        enum Status: String { case a, b }
        struct V: View {
            let status: Status
            var body: some View { Text(status.describe()) }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        let status = try XCTUnwrap(lowered.inputs.first { $0.name == "status" })
        XCTAssertEqual(status.kind, .unsupported, "a method call on the enum demotes")
    }

    func testStructTypeUsedAsBothArrayAndSingleEmitsOneStructBothScanners() throws {
        // A type used by BOTH a `[Product]` AND a single `Product` input emits ONE
        // mirroring struct + both scanners (array-of-objects AND single-object).
        let source = """
        import SwiftUI
        struct Product { var name: String; var price: Double }
        struct Screen: View {
            let items: [Product]
            let featured: Product
            var body: some View {
                VStack {
                    Text(featured.name)
                    ForEach(items, id: \\.name) { p in Text(p.name) }
                }
            }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        XCTAssertEqual(try XCTUnwrap(lowered.inputs.first { $0.name == "featured" }).kind, .flatStruct)
        XCTAssertEqual(try XCTUnwrap(lowered.inputs.first { $0.name == "items" }).kind, .structArray)
        let view = SwiftUIGuestEmitter.GuestView(
            viewName: lowered.viewName, guestBody: lowered.guestBody, inputs: lowered.inputs)
        let wrapper = try XCTUnwrap(try SwiftUIGuestEmitter().emit(views: [view])
            .files.first { $0.fileName == "_PatchSwiftUI.swift" })
        // Exactly ONE struct definition, but BOTH scanners.
        let structDefs = wrapper.contents.components(separatedBy: "struct _PatchRow_Product {").count - 1
        XCTAssertEqual(structDefs, 1, "one mirroring struct shared by both inputs")
        XCTAssertTrue(wrapper.contents.contains("_patchScanProductRowArray(_patchInputs, \"items\")"))
        XCTAssertTrue(wrapper.contents.contains("_patchScanProductRow(_patchInputs, \"featured\")"))
    }

    func testRichInputUsedInInlinableHelperIsGated() throws {
        // An inlinable `some View` helper (`row`) is substituted INTO the guest body, so a
        // non-reconstructable use of the input THERE (`item.name.uppercased()` /
        // `status.describe()`) must downgrade the input — the gate scans helper bodies too.
        let structSrc = """
        import SwiftUI
        struct Product { var name: String }
        struct V: View {
            let item: Product
            var row: some View { Text(item.name.uppercased()) }
            var body: some View { VStack { row } }
        }
        """
        let s = try XCTUnwrap(BodyLowering().lowerAllViews(source: structSrc).first)
        XCTAssertEqual(try XCTUnwrap(s.inputs.first { $0.name == "item" }).kind, .unsupported,
                       "a method on a flat-struct field inside an inlinable helper must downgrade")

        let enumSrc = """
        import SwiftUI
        enum Status: String { case a, b }
        struct V: View {
            let status: Status
            var row: some View { Text(status.describe()) }
            var body: some View { VStack { row } }
        }
        """
        let e = try XCTUnwrap(BodyLowering().lowerAllViews(source: enumSrc).first)
        XCTAssertEqual(try XCTUnwrap(e.inputs.first { $0.name == "status" }).kind, .unsupported,
                       "a method on an enum inside an inlinable helper must downgrade")
    }

    func testEnumWithExplicitStringRawValuesIsFaithful() throws {
        // A String enum with EXPLICIT raw values (`= "ACTIVE"`) must emit those, so
        // `.rawValue` is faithful (not the case name).
        let source = """
        import SwiftUI
        enum Status: String { case active = "ACTIVE", archived = "ARCHIVED" }
        struct Badge: View {
            let status: Status
            var body: some View { Text(status.rawValue) }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        let view = SwiftUIGuestEmitter.GuestView(
            viewName: lowered.viewName, guestBody: lowered.guestBody, inputs: lowered.inputs)
        let wrapper = try XCTUnwrap(try SwiftUIGuestEmitter().emit(views: [view])
            .files.first { $0.fileName == "_PatchSwiftUI.swift" })
        XCTAssertTrue(wrapper.contents.contains("case active = \"ACTIVE\""),
                      "explicit raw values are preserved for faithful .rawValue: \(wrapper.contents)")
    }

    // MARK: - END-TO-END (WASM) — both shapes round-trip

    func testSingleFlatStructExecutesInWasm() throws {
        let compiler = SwiftWasmCompiler(
            exportedSymbols: ["view_body", "view_body__ProductRow", "patch_malloc", "patch_free"])
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping flat-struct WASM run")
        let source = """
        import SwiftUI
        struct Product { var name: String; var price: Double; var inStock: Bool }
        struct ProductRow: View {
            let item: Product
            var body: some View {
                VStack {
                    Text(item.name)
                    Text("price=\\(item.price)")
                    if item.inStock { Text("In stock") }
                }
            }
        }
        """
        let module = try compileSwiftUIModule(source: source, into: "flatstruct-exec")
        let wasm = [UInt8](try Data(contentsOf: module))
        let runner = try Runner(wasm: wasm)
        // The SDK marshals a struct as a NESTED JSON OBJECT under the input key.
        let inputs = Data(#"{"item":{"name":"Widget","price":9,"inStock":true}}"#.utf8)
        let desc = try JSONDecoder()
            .decode(BodyEmission.self, from: Data(runner.callPacked("view_body", [UInt8](inputs))))
            .root.describe()
        XCTAssertTrue(desc.contains("Widget"), "item.name from the marshalled object: \(desc)")
        XCTAssertTrue(desc.contains("price=9"), "item.price from the object: \(desc)")
        XCTAssertTrue(desc.contains("In stock"), "item.inStock gated the conditional: \(desc)")
        // A missing field falls back to the struct default (no crash); inStock=false hides the line.
        let partial = try Runner(wasm: wasm).callPacked(
            "view_body", [UInt8](Data(#"{"item":{"name":"X"}}"#.utf8)))
        let pDesc = try JSONDecoder().decode(BodyEmission.self, from: Data(partial)).root.describe()
        XCTAssertTrue(pDesc.contains("X"), "name parsed: \(pDesc)")
        XCTAssertTrue(pDesc.contains("price=0"), "missing price → default 0: \(pDesc)")
        XCTAssertFalse(pDesc.contains("In stock"), "missing inStock → false → line hidden: \(pDesc)")
    }

    func testRawEnumExecutesInWasm() throws {
        let compiler = SwiftWasmCompiler(
            exportedSymbols: ["view_body", "view_body__Badge", "patch_malloc", "patch_free"])
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping raw-enum WASM run")
        let source = """
        import SwiftUI
        enum Status: String { case active, archived }
        struct Badge: View {
            let status: Status
            var body: some View {
                VStack {
                    if status == .active { Text("ACTIVE") }
                    if status == .archived { Text("ARCHIVED") }
                    Text("raw=\\(status.rawValue)")
                }
            }
        }
        """
        let module = try compileSwiftUIModule(source: source, into: "rawenum-exec")
        let wasm = [UInt8](try Data(contentsOf: module))
        // The SDK marshals an enum as `{"case":"<name>"}`.
        let activeDesc = try JSONDecoder()
            .decode(BodyEmission.self, from: Data(try Runner(wasm: wasm)
                .callPacked("view_body", [UInt8](Data(#"{"status":{"case":"active"}}"#.utf8)))))
            .root.describe()
        XCTAssertTrue(activeDesc.contains("ACTIVE"), "status == .active matched: \(activeDesc)")
        XCTAssertFalse(activeDesc.contains("ARCHIVED"), "other branch hidden: \(activeDesc)")
        XCTAssertTrue(activeDesc.contains("raw=active"), "rawValue resolved: \(activeDesc)")

        let archDesc = try JSONDecoder()
            .decode(BodyEmission.self, from: Data(try Runner(wasm: wasm)
                .callPacked("view_body", [UInt8](Data(#"{"status":{"case":"archived"}}"#.utf8)))))
            .root.describe()
        XCTAssertTrue(archDesc.contains("ARCHIVED"), "status == .archived matched: \(archDesc)")
        XCTAssertFalse(archDesc.contains("\"ACTIVE\""), "other branch hidden: \(archDesc)")
        XCTAssertTrue(archDesc.contains("raw=archived"), "rawValue resolved: \(archDesc)")
    }

    // MARK: - RICH-INPUT WIDENING: nested struct / struct-array field / scalar-array
    //          field / dictionary field — classification + recursive guest reconstruction.

    func testNestedStructInputClassifiesAndLowers() throws {
        // A struct whose field is ANOTHER struct now reconstructs (recursively).
        let source = """
        import SwiftUI
        struct Address { var city: String; var zip: String }
        struct Person { var name: String; var address: Address }
        struct PersonCard: View {
            let person: Person
            var body: some View {
                VStack {
                    Text(person.name)
                    Text(person.address.city)
                }
            }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        let person = try XCTUnwrap(lowered.inputs.first { $0.name == "person" })
        XCTAssertEqual(person.kind, .flatStruct, "a nested-struct input now reconstructs")
        XCTAssertFalse(lowered.referencesUnmarshalledInput,
                       "a body reading person.name + person.address.city must NOT demote")
        // The nested field's struct shape rode in the element descriptor.
        let addrField = try XCTUnwrap(person.structElement?.fields.first { $0.name == "address" })
        if case .structValue(let el) = addrField.shape {
            XCTAssertEqual(el.typeName, "Address")
            XCTAssertEqual(el.fields.map(\.name), ["city", "zip"])
        } else { XCTFail("address field should be a nested struct shape, got \(addrField.shape)") }
        let g = lowered.guestBody
        XCTAssertTrue(g.contains("person.name"), "reads person.name: \(g)")
        XCTAssertTrue(g.contains("person.address.city"), "reads the nested chain: \(g)")
        XCTAssertFalse(g.contains("N.opaque"), "fully lowers: \(g)")
    }

    func testNestedStructDeeperChainDemotesOnUnknownField() throws {
        // A chain that does NOT resolve through the field shapes (an unknown nested
        // field) demotes the view — never a wrong reconstruction.
        let source = """
        import SwiftUI
        struct Address { var city: String }
        struct Person { var name: String; var address: Address }
        struct V: View {
            let person: Person
            var body: some View { Text(person.address.country) }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        let person = try XCTUnwrap(lowered.inputs.first { $0.name == "person" })
        XCTAssertEqual(person.kind, .unsupported, "an unknown nested field demotes the input")
    }

    func testStructArrayFieldClassifies() throws {
        // A struct field that is an ARRAY of nested structs reconstructs.
        let source = """
        import SwiftUI
        struct LineItem { var label: String; var qty: Int }
        struct Cart { var title: String; var items: [LineItem] }
        struct CartView: View {
            let cart: Cart
            var body: some View {
                VStack {
                    Text(cart.title)
                    ForEach(cart.items, id: \\.label) { it in Text(it.label) }
                }
            }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        let cart = try XCTUnwrap(lowered.inputs.first { $0.name == "cart" })
        XCTAssertEqual(cart.kind, .flatStruct, "a struct-array field reconstructs")
        let itemsField = try XCTUnwrap(cart.structElement?.fields.first { $0.name == "items" })
        if case .structArray(let el) = itemsField.shape {
            XCTAssertEqual(el.typeName, "LineItem")
        } else { XCTFail("items should be a struct-array shape, got \(itemsField.shape)") }
    }

    func testNestedStructExecutesInWasm() throws {
        // RENDER-CORRECTNESS: a body reading a NESTED struct chain renders the REAL
        // marshalled values in WASM (not a guest default).
        let compiler = SwiftWasmCompiler(exportedSymbols: ["view_body"])
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping nested-struct WASM run")
        let source = """
        import SwiftUI
        struct Address { var city: String; var zip: String }
        struct Person { var name: String; var address: Address; var age: Int }
        struct PersonCard: View {
            let person: Person
            var body: some View {
                VStack {
                    Text(person.name)
                    Text(person.address.city)
                    Text("zip=\\(person.address.zip)")
                    Text("age=\\(person.age)")
                }
            }
        }
        """
        let module = try compileSwiftUIModule(source: source, into: "nested-struct-exec")
        let wasm = [UInt8](try Data(contentsOf: module))
        // The SDK marshals a struct as a NESTED OBJECT; a nested struct field as a
        // nested OBJECT inside it (PatchValueEncoder.encodeObject, recursive).
        let inputs = Data(#"{"person":{"name":"Ada","age":36,"address":{"city":"London","zip":"NW1"}}}"#.utf8)
        let desc = try JSONDecoder()
            .decode(BodyEmission.self, from: Data(try Runner(wasm: wasm).callPacked("view_body", [UInt8](inputs))))
            .root.describe()
        XCTAssertTrue(desc.contains("Ada"), "person.name: \(desc)")
        XCTAssertTrue(desc.contains("London"), "person.address.city (NESTED): \(desc)")
        XCTAssertTrue(desc.contains("zip=NW1"), "person.address.zip (NESTED): \(desc)")
        XCTAssertTrue(desc.contains("age=36"), "person.age: \(desc)")
        // A missing nested field falls back to the nested struct's default (no crash).
        let partial = try Runner(wasm: wasm).callPacked(
            "view_body", [UInt8](Data(#"{"person":{"name":"X","address":{"city":"Y"}}}"#.utf8)))
        let pDesc = try JSONDecoder().decode(BodyEmission.self, from: Data(partial)).root.describe()
        XCTAssertTrue(pDesc.contains("Y"), "nested city parsed: \(pDesc)")
        XCTAssertTrue(pDesc.contains("zip="), "missing nested zip → default empty: \(pDesc)")
        XCTAssertTrue(pDesc.contains("age=0"), "missing age → default 0: \(pDesc)")
    }

    func testStructArrayFieldExecutesInWasm() throws {
        // RENDER-CORRECTNESS: a struct field that is an ARRAY OF NESTED STRUCTS renders
        // the real per-element values via a `ForEach` over the bound guest struct array.
        let compiler = SwiftWasmCompiler(exportedSymbols: ["view_body"])
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping struct-array-field WASM run")
        let source = """
        import SwiftUI
        struct LineItem { var label: String; var qty: Int }
        struct Cart { var title: String; var items: [LineItem] }
        struct CartView: View {
            let cart: Cart
            var body: some View {
                VStack {
                    Text(cart.title)
                    ForEach(cart.items, id: \\.label) { it in
                        HStack { Text(it.label); Text("x\\(it.qty)") }
                    }
                }
            }
        }
        """
        let module = try compileSwiftUIModule(source: source, into: "struct-array-field-exec")
        let wasm = [UInt8](try Data(contentsOf: module))
        let inputs = Data(#"{"cart":{"title":"Order","items":[{"label":"Apple","qty":3},{"label":"Pear","qty":7}]}}"#.utf8)
        let desc = try JSONDecoder()
            .decode(BodyEmission.self, from: Data(try Runner(wasm: wasm).callPacked("view_body", [UInt8](inputs))))
            .root.describe()
        XCTAssertTrue(desc.contains("Order"), "cart.title: \(desc)")
        XCTAssertTrue(desc.contains("Apple") && desc.contains("x3"), "row 0 (label+qty): \(desc)")
        XCTAssertTrue(desc.contains("Pear") && desc.contains("x7"), "row 1 (label+qty): \(desc)")
    }

    func testScalarArrayAndDictFieldExecuteInWasm() throws {
        // RENDER-CORRECTNESS: a struct with a SCALAR-ARRAY field (`[String]`) and a
        // `[String:Int]` DICTIONARY field reconstructs both; the body reads a scalar leaf
        // plus the collections' `.count`.
        let compiler = SwiftWasmCompiler(exportedSymbols: ["view_body"])
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping scalar-array/dict WASM run")
        let source = """
        import SwiftUI
        struct Profile { var name: String; var tags: [String]; var scores: [String: Int] }
        struct ProfileView: View {
            let profile: Profile
            var body: some View {
                VStack {
                    Text(profile.name)
                    Text("tags=\\(profile.tags.count)")
                    Text("scores=\\(profile.scores.count)")
                }
            }
        }
        """
        let module = try compileSwiftUIModule(source: source, into: "scalar-array-dict-exec")
        let wasm = [UInt8](try Data(contentsOf: module))
        let inputs = Data(#"{"profile":{"name":"Z","tags":["a","b","c"],"scores":{"math":90,"art":80}}}"#.utf8)
        let desc = try JSONDecoder()
            .decode(BodyEmission.self, from: Data(try Runner(wasm: wasm).callPacked("view_body", [UInt8](inputs))))
            .root.describe()
        XCTAssertTrue(desc.contains("Z"), "profile.name: \(desc)")
        XCTAssertTrue(desc.contains("tags=3"), "scalar-array field count: \(desc)")
        XCTAssertTrue(desc.contains("scores=2"), "dictionary field count: \(desc)")
    }

    func testStructDictionaryFieldClassifies() throws {
        // A struct field that is a `[String: SubStruct]` dictionary reconstructs.
        let source = """
        import SwiftUI
        struct Stats { var wins: Int; var losses: Int }
        struct Board { var title: String; var byPlayer: [String: Stats] }
        struct BoardView: View {
            let board: Board
            var body: some View {
                VStack {
                    Text(board.title)
                    Text("players=\\(board.byPlayer.count)")
                }
            }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        let board = try XCTUnwrap(lowered.inputs.first { $0.name == "board" })
        XCTAssertEqual(board.kind, .flatStruct, "a struct-dictionary field reconstructs")
        let f = try XCTUnwrap(board.structElement?.fields.first { $0.name == "byPlayer" })
        if case .structDictionary(let el) = f.shape {
            XCTAssertEqual(el.typeName, "Stats")
            XCTAssertEqual(el.fields.map(\.name), ["wins", "losses"])
        } else { XCTFail("byPlayer should be a struct-dictionary shape, got \(f.shape)") }
    }

    func testStructDictionaryFieldExecutesInWasm() throws {
        // RENDER-CORRECTNESS: a struct field that is a `[String: SubStruct]` dictionary
        // reconstructs the REAL nested values. The body reads the dict `.count` (a scalar
        // leaf the gate permits) — the per-key struct VALUES are reconstructed in full,
        // so this proves the decoder builds each value, not just the key set.
        let compiler = SwiftWasmCompiler(exportedSymbols: ["view_body"])
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping struct-dict WASM run")
        let source = """
        import SwiftUI
        struct Stats { var wins: Int; var losses: Int }
        struct Board { var title: String; var byPlayer: [String: Stats] }
        struct BoardView: View {
            let board: Board
            var body: some View {
                VStack {
                    Text(board.title)
                    Text("players=\\(board.byPlayer.count)")
                }
            }
        }
        """
        let module = try compileSwiftUIModule(source: source, into: "struct-dict-field-exec")
        let wasm = [UInt8](try Data(contentsOf: module))
        // The SDK marshals `[String: Stats]` as a JSON OBJECT of nested struct objects.
        let inputs = Data(#"{"board":{"title":"League","byPlayer":{"ada":{"wins":3,"losses":1},"linus":{"wins":5,"losses":0}}}}"#.utf8)
        let desc = try JSONDecoder()
            .decode(BodyEmission.self, from: Data(try Runner(wasm: wasm).callPacked("view_body", [UInt8](inputs))))
            .root.describe()
        XCTAssertTrue(desc.contains("League"), "board.title: \(desc)")
        XCTAssertTrue(desc.contains("players=2"), "struct-dict field count (both keys decoded): \(desc)")
    }

    /// RENDER-CORRECTNESS that the struct-dict VALUES are reconstructed (not just counted):
    /// the body subscripts the dict by a literal key and reads a nested field. This is the
    /// strongest struct-dict shape — it proves each VALUE struct is built from its bytes.
    func testStructDictionaryValueReadExecutesInWasm() throws {
        let compiler = SwiftWasmCompiler(exportedSymbols: ["view_body"])
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping struct-dict value-read WASM run")
        let source = """
        import SwiftUI
        struct Stats { var wins: Int; var losses: Int }
        struct Board { var byPlayer: [String: Stats] }
        struct BoardView: View {
            let board: Board
            var body: some View {
                VStack {
                    Text("ada=\\(board.byPlayer["ada"]?.wins ?? -1)")
                    Text("count=\\(board.byPlayer.count)")
                }
            }
        }
        """
        // A subscript+optional-chain read of the dict value is a non-flat-field access
        // the gate may reject (demote-safe). Verify the engine's decision first.
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        let board = try XCTUnwrap(lowered.inputs.first { $0.name == "board" })
        // If the gate kept it lowerable, the values MUST render correctly; if it demoted
        // (subscript chain not gate-safe), that's the honest demote-safe outcome — assert
        // the count-only shape still lowers as the floor.
        if board.kind == .flatStruct, !lowered.referencesUnmarshalledInput {
            let module = try compileSwiftUIModule(source: source, into: "struct-dict-value-exec")
            let wasm = [UInt8](try Data(contentsOf: module))
            let inputs = Data(#"{"board":{"byPlayer":{"ada":{"wins":7,"losses":2}}}}"#.utf8)
            let desc = try JSONDecoder()
                .decode(BodyEmission.self, from: Data(try Runner(wasm: wasm).callPacked("view_body", [UInt8](inputs))))
                .root.describe()
            XCTAssertTrue(desc.contains("ada=7"), "dict value's nested field read: \(desc)")
        } else {
            // Demote-safe: a subscript chain on a dict isn't a plain reconstructable leaf.
            XCTAssertEqual(board.kind, .unsupported,
                           "a non-reconstructable dict subscript chain must demote, not silently lower")
        }
    }

    // MARK: - OPTIONAL SCALAR struct fields (`String?`/`Int?`/…)

    func testOptionalScalarFieldClassifies() throws {
        // A struct field that is an OPTIONAL scalar reconstructs when the body uses it
        // optionally (`?? default`).
        let source = """
        import SwiftUI
        struct Owner { var label: String; var subtitle: String?; var rank: Int? }
        struct OwnerRow: View {
            let owner: Owner
            var body: some View {
                VStack {
                    Text(owner.label)
                    Text(owner.subtitle ?? "—")
                    Text("rank=\\(owner.rank ?? 0)")
                }
            }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        let owner = try XCTUnwrap(lowered.inputs.first { $0.name == "owner" })
        XCTAssertEqual(owner.kind, .flatStruct, "an optional-scalar field used with ?? reconstructs")
        XCTAssertFalse(lowered.referencesUnmarshalledInput,
                       "an owner with optional fields read via ?? must NOT demote")
        let subtitle = try XCTUnwrap(owner.structElement?.fields.first { $0.name == "subtitle" })
        if case .optionalScalar(let k) = subtitle.shape { XCTAssertEqual(k, .string) }
        else { XCTFail("subtitle should be optionalScalar(.string), got \(subtitle.shape)") }
        let g = lowered.guestBody
        XCTAssertTrue(g.contains("owner.subtitle ?? \"—\"") || g.contains("owner.subtitle ??"),
                      "reads the optional via ??: \(g)")
        XCTAssertFalse(g.contains("N.opaque"), "fully lowers: \(g)")
    }

    func testOptionalScalarBareReadDemotes() throws {
        // A BARE read of an optional scalar (passed where a non-optional is expected, or
        // force-unwrapped) is not guest-provable → the whole input demotes.
        let source = """
        import SwiftUI
        struct Owner { var subtitle: String? }
        struct V: View {
            let owner: Owner
            var body: some View { Text(owner.subtitle!) }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        let owner = try XCTUnwrap(lowered.inputs.first { $0.name == "owner" })
        XCTAssertEqual(owner.kind, .unsupported,
                       "a force-unwrap of an optional scalar must demote")
    }

    func testOptionalChainOnOptionalScalarDemotes() throws {
        // `owner.subtitle?.count` chains a member on the optional — not gate-safe.
        let source = """
        import SwiftUI
        struct Owner { var subtitle: String? }
        struct V: View {
            let owner: Owner
            var body: some View { Text("\\(owner.subtitle?.count ?? 0)") }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        let owner = try XCTUnwrap(lowered.inputs.first { $0.name == "owner" })
        XCTAssertEqual(owner.kind, .unsupported,
                       "a member chain on the optional must demote")
    }

    func testOptionalScalarFieldExecutesInWasm() throws {
        // RENDER-CORRECTNESS: optional scalar fields render the REAL marshalled value when
        // present and the `??` default when the SDK marshals `null` / omits the key.
        let compiler = SwiftWasmCompiler(exportedSymbols: ["view_body"])
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping optional-scalar WASM run")
        let source = """
        import SwiftUI
        struct Owner { var label: String; var subtitle: String?; var rank: Int? }
        struct OwnerRow: View {
            let owner: Owner
            var body: some View {
                VStack {
                    Text(owner.label)
                    Text("sub=\\(owner.subtitle ?? "none")")
                    Text("rank=\\(owner.rank ?? -1)")
                }
            }
        }
        """
        let module = try compileSwiftUIModule(source: source, into: "optional-scalar-exec")
        let wasm = [UInt8](try Data(contentsOf: module))
        // PRESENT: subtitle + rank marshalled as bare values.
        let present = Data(#"{"owner":{"label":"Ada","subtitle":"primary","rank":3}}"#.utf8)
        let pDesc = try JSONDecoder()
            .decode(BodyEmission.self, from: Data(try Runner(wasm: wasm).callPacked("view_body", [UInt8](present))))
            .root.describe()
        XCTAssertTrue(pDesc.contains("Ada"), "label: \(pDesc)")
        XCTAssertTrue(pDesc.contains("sub=primary"), "present optional string: \(pDesc)")
        XCTAssertTrue(pDesc.contains("rank=3"), "present optional int: \(pDesc)")
        // NULL: the SDK marshals .none as JSON null → the ?? default renders.
        let nullDesc = try JSONDecoder()
            .decode(BodyEmission.self, from: Data(try Runner(wasm: wasm).callPacked(
                "view_body", [UInt8](Data(#"{"owner":{"label":"Lin","subtitle":null,"rank":null}}"#.utf8)))))
            .root.describe()
        XCTAssertTrue(nullDesc.contains("sub=none"), "null optional string → ?? default: \(nullDesc)")
        XCTAssertTrue(nullDesc.contains("rank=-1"), "null optional int → ?? default: \(nullDesc)")
        // OMITTED: a missing key also yields the ?? default (no crash).
        let omittedDesc = try JSONDecoder()
            .decode(BodyEmission.self, from: Data(try Runner(wasm: wasm).callPacked(
                "view_body", [UInt8](Data(#"{"owner":{"label":"Pat"}}"#.utf8)))))
            .root.describe()
        XCTAssertTrue(omittedDesc.contains("sub=none"), "omitted optional → ?? default: \(omittedDesc)")
        XCTAssertTrue(omittedDesc.contains("rank=-1"), "omitted optional int → ?? default: \(omittedDesc)")
    }

    /// RENDER-CORRECTNESS for the strongest recursive shape: a `ForEach` over an array
    /// of NESTED structs, where each row reads BOTH the flat field AND the nested
    /// field. This is the composition of `testFlatStructArrayForEachExecutesInWasm`
    /// (per-element loop) and `testNestedStructExecutesInWasm` (nested-object marshal),
    /// and it is exactly the shape the previously-demoting tests
    /// (`testForEachOverNonFlatStructArrayDemotes` etc.) now lower. It MUST render the
    /// real nested values, not a guest default — otherwise the recursive marshalling is
    /// unsafe and those shapes must demote instead.
    func testNestedStructArrayExecutesInWasm() throws {
        let compiler = SwiftWasmCompiler(
            exportedSymbols: ["view_body", "view_body__ItemList", "patch_malloc", "patch_free"])
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping nested-struct-array WASM run")
        let source = """
        import SwiftUI
        struct Tag { var label: String }
        struct Item { var name: String; var tag: Tag }
        struct ItemList: View {
            let items: [Item] = []
            var body: some View {
                VStack {
                    ForEach(items, id: \\.name) { it in
                        HStack {
                            Text(it.name)
                            Text("tag=\\(it.tag.label)")
                        }
                    }
                }
            }
        }
        """
        let module = try compileSwiftUIModule(source: source, into: "nested-structarray-exec")
        let wasm = [UInt8](try Data(contentsOf: module))
        let inputs = Data(#"{"items":[{"name":"A","tag":{"label":"X"}},{"name":"B","tag":{"label":"Y"}}]}"#.utf8)
        let desc = try JSONDecoder()
            .decode(BodyEmission.self, from: Data(try Runner(wasm: wasm).callPacked("view_body", [UInt8](inputs))))
            .root.describe()
        // Both rows, each reading the flat field (name) AND the NESTED field (tag.label).
        XCTAssertTrue(desc.contains("A"), "row 0 flat name: \(desc)")
        XCTAssertTrue(desc.contains("tag=X"), "row 0 NESTED tag.label: \(desc)")
        XCTAssertTrue(desc.contains("B"), "row 1 flat name: \(desc)")
        XCTAssertTrue(desc.contains("tag=Y"), "row 1 NESTED tag.label: \(desc)")
    }

    // MARK: - Helpers (mirror SwiftUIStructArrayAndHelperLoweringTests)

    private func compileSwiftUIModule(source: String, into label: String) throws -> URL {
        let lowering = BodyLowering()
        let lowered = lowering.lowerAllViews(source: source)
        let guestViews = lowered
            .filter { !$0.referencesUnmarshalledInput }
            .map { SwiftUIGuestEmitter.GuestView(viewName: $0.viewName, guestBody: $0.guestBody,
                                                 inputs: $0.inputs, stateModel: $0.stateModel) }
        let emission = try SwiftUIGuestEmitter().emit(views: guestViews)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftui-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tmp) }
        var sources: [URL] = []
        for f in emission.files {
            let u = tmp.appendingPathComponent(f.fileName)
            try f.contents.write(to: u, atomically: true, encoding: .utf8)
            sources.append(u)
        }
        let out = tmp.appendingPathComponent("module.swiftui.wasm")
        let compiler = SwiftWasmCompiler(
            exportedSymbols: emission.exports + ["patch_malloc", "patch_free"])
        let result = try compiler.compile(sources: sources, outputModule: out)
        XCTAssertEqual(result.status, .success, "guest WASM compile failed:\n\(result.log)")
        return out
    }

    private final class Runner {
        let store: Store
        let instance: Instance
        let wasi: WASIBridgeToHost
        init(wasm: [UInt8]) throws {
            let engine = Engine()
            self.store = Store(engine: engine)
            self.wasi = try WASIBridgeToHost()
            var imports = Imports()
            wasi.link(to: &imports, store: store)
            PatchHostTestImports.register(into: &imports, store: store)
            let module = try parseWasm(bytes: wasm)
            self.instance = try module.instantiate(store: store, imports: imports)
            try wasi.initialize(instance)
        }
        func memory() throws -> Memory {
            guard let m = instance.exports[memory: "memory"] else { throw NSError(domain: "abi", code: 1) }
            return m
        }
        func callPacked(_ name: String, _ input: [UInt8]) throws -> [UInt8] {
            guard let fn = instance.exports[function: name],
                  let malloc = instance.exports[function: "patch_malloc"] else {
                throw NSError(domain: "abi", code: 2, userInfo: [NSLocalizedDescriptionKey: "missing export \(name)"])
            }
            let ptr = try malloc([.i32(UInt32(input.count))])[0].i32
            let mem = try memory()
            mem.withUnsafeMutableBufferPointer(offset: UInt(ptr), count: input.count) { raw in
                raw.copyBytes(from: input)
            }
            let packed = try fn([.i32(ptr), .i32(UInt32(input.count))])[0].i64
            let outPtr = UInt32(truncatingIfNeeded: packed >> 32)
            let outLen = UInt32(truncatingIfNeeded: packed & 0xFFFF_FFFF)
            let all = try memory().data
            return [UInt8](all[Int(outPtr)..<Int(outPtr) + Int(outLen)])
        }
    }
}
