// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
import WasmKit
import WasmKitWASI
import SwiftSyntax
import SwiftParser
@testable import CodeGenerator
@testable import Compiler
import ViewNodeIR

/// Tests for NON-SCALAR `@State`/`@Binding`/`let` input marshalling on the engine
/// (guest BIND) side. The contract:
///   * Arrays of a single scalar element (`[Int]`/`[String]`/`[Double]`/`[Bool]`)
///     are guest-reconstructable: the body reads the REAL array (engine emits an
///     `_patchScan*Array` binding), and the SDK marshals the real value in.
///   * A struct/enum/dictionary/custom value type is NOT guest-reconstructable. A
///     body that READS one DEMOTES to native (`referencesUnmarshalledInput`), so
///     the engine never binds a wrong literal default while claiming the view is
///     `thunkSafe`. The body never silently renders a stale/default value.
final class SwiftUINonScalarInputTests: XCTestCase {

    // MARK: - Array-of-scalar inputs (guest-reconstructable)

    func testArrayOfScalarsClassifiedByElementType() {
        XCTAssertEqual(BodyLowering.arrayElementKind("[Int]"), .intArray)
        XCTAssertEqual(BodyLowering.arrayElementKind("[String]"), .stringArray)
        XCTAssertEqual(BodyLowering.arrayElementKind("[Double]"), .doubleArray)
        XCTAssertEqual(BodyLowering.arrayElementKind("[CGFloat]"), .doubleArray)
        XCTAssertEqual(BodyLowering.arrayElementKind("[Bool]"), .boolArray)
        XCTAssertEqual(BodyLowering.arrayElementKind("Array<Int>"), .intArray)
        // Arrays of NON-scalars are not array-of-scalar kinds (→ unsupported upstream).
        XCTAssertNil(BodyLowering.arrayElementKind("[Item]"))
        XCTAssertNil(BodyLowering.arrayElementKind("[Int: String]"))
        XCTAssertNil(BodyLowering.arrayElementKind("Int"))
    }

    func testArrayInputMarshalsWithArrayScanner() throws {
        let source = """
        import SwiftUI
        struct ListView: View {
            let scores: [Int] = [10, 20]
            var body: some View {
                VStack {
                    ForEach(scores, id: \\.self) { s in
                        Text("\\(s)")
                    }
                }
            }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        let scores = try XCTUnwrap(lowered.inputs.first { $0.name == "scores" })
        XCTAssertEqual(scores.kind, .intArray, "an [Int] property is an int-array input")
        XCTAssertTrue(scores.kind.guestReconstructable)
        // A body reading an array-of-scalars does NOT demote.
        XCTAssertFalse(lowered.referencesUnmarshalledInput)

        // The guest emitter binds it via the ARRAY scanner (real value), not a default.
        let view = SwiftUIGuestEmitter.GuestView(
            viewName: lowered.viewName, guestBody: lowered.guestBody, inputs: lowered.inputs)
        let emission = try SwiftUIGuestEmitter().emit(views: [view])
        let wrapper = try XCTUnwrap(emission.files.first { $0.fileName == "_PatchSwiftUI.swift" })
        XCTAssertTrue(
            wrapper.contents.contains("_patchScanIntArray(_patchInputs, \"scores\")"),
            "the [Int] input is bound from the array scanner")
    }

    // MARK: - Struct / enum inputs (NOT guest-reconstructable → demote)

    func testBodyReadingStructStateDemotesToNative() throws {
        // A body that READS a struct `@State` FIELD. The struct itself is never guest-
        // reconstructed. With a SEPARATE-file thunk the field read (`profile.name`) leaks a
        // non-reconstructable input and the cross-file thunk can't host-resolve a `private`
        // member, so the view DEMOTES — never binds a wrong default. With a SAME-FILE thunk
        // (the default) the in-file thunk CAN evaluate `self.profile.name` natively → a
        // String host token, so the FIELD value is host-resolved faithfully and the view
        // lowers (the struct value still isn't reconstructed; only the String it yields is).
        let source = """
        import SwiftUI
        struct CardView: View {
            struct Profile { var name: String; var age: Int }
            @State private var profile = Profile(name: "Ada", age: 36)
            var body: some View {
                VStack {
                    Text(profile.name)
                    Text("static")
                }
            }
        }
        """
        // Separate-file: the struct-field read demotes the view.
        let separate = try XCTUnwrap(
            BodyLowering().lowerAllViews(source: source, sameFileThunk: false).first)
        let profile = try XCTUnwrap(separate.inputs.first { $0.name == "profile" })
        XCTAssertEqual(profile.kind, .unsupported)
        XCTAssertFalse(profile.kind.guestReconstructable)
        XCTAssertTrue(separate.referencesUnmarshalledInput,
                      "separate-file: a body reading a private struct @State field must demote")
        // Same-file: the field read host-resolves as a String token; the view lowers.
        let same = try XCTUnwrap(
            BodyLowering().lowerAllViews(source: source, sameFileThunk: true).first)
        XCTAssertFalse(same.referencesUnmarshalledInput,
                       "same-file: the struct-field read host-resolves, so no demotion")
        XCTAssertEqual(same.hostTokens.filter { $0.kind == .string && $0.source == "profile.name" }.count, 1,
                       "same-file: profile.name host-projects as a string token: \(same.hostTokens)")
    }

    func testUnreferencedStructStateDoesNotDemote() throws {
        // A struct `@State` the body NEVER reads is harmless: binding its default is
        // dead code, so the view can still auto-route. (We only demote on a real read.)
        let source = """
        import SwiftUI
        struct CardView: View {
            struct Profile { var name: String }
            @State private var profile = Profile(name: "Ada")
            let title: String = "Hello"
            var body: some View {
                Text(title)
            }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        XCTAssertNotNil(lowered.inputs.first { $0.name == "profile" && $0.kind == .unsupported })
        XCTAssertFalse(lowered.referencesUnmarshalledInput,
                       "an UNREAD struct @State must not force demotion")
    }

    // MARK: - SwiftData demote diagnostic (the modern-app coverage wall, made visible)

    /// Parse `source`, find the first struct, return its SwiftData property names (sorted).
    private func swiftDataNames(_ source: String) throws -> [String] {
        let tree = Parser.parse(source: source)
        let decl = try XCTUnwrap(tree.statements.lazy
            .compactMap { $0.item.as(StructDeclSyntax.self) }.first,
            "no struct decl in source")
        return BodyLowering.swiftDataPropertyNames(of: decl).sorted()
    }

    func testSwiftDataDetectorFlagsQueryBindableContext() throws {
        // The attribute-based SwiftData detector recognizes @Query (fetch result),
        // @Bindable (a bound @Model), and @Environment(\\.modelContext) — and does NOT flag
        // plain @State/@Binding/let. This is the signal that turns the invisible #1
        // modern-SwiftUI-app coverage wall into an actionable "blocked by SwiftData" message.
        let names = try swiftDataNames("""
        import SwiftUI
        import SwiftData
        struct MyPlantsScreen: View {
            @Query private var plants: [Plant]
            @Bindable var current: Plant
            @Environment(\\.modelContext) private var modelContext
            @Environment(\\.dismiss) private var dismiss
            @State private var count = 0
            @Binding var title: String
            let subtitle: String = "x"
            var body: some View { Text(subtitle) }
        }
        """)
        XCTAssertEqual(names, ["current", "modelContext", "plants"],
                       "only @Query/@Bindable/@Environment(modelContext) are flagged: \(names)")
    }

    func testSwiftDataDetectorEmptyForNonSwiftDataView() throws {
        // A view with no SwiftData wrappers flags nothing (no false positives — the
        // diagnostic must never mislabel an ordinary @State/@Environment view).
        let names = try swiftDataNames("""
        import SwiftUI
        struct PlainView: View {
            @State private var n = 0
            @Environment(\\.colorScheme) private var scheme
            let title: String
            var body: some View { Text(title) }
        }
        """)
        XCTAssertEqual(names, [], "a non-SwiftData view flags no SwiftData blockers: \(names)")
    }

    // MARK: - Property collection-guard host-projection (1.6.5 coverage lever)

    func testEmptyStateGuardOverQueryCollectionLowers() throws {
        // The #1 SwiftData/data-view condition shape: `if items.isEmpty { Empty } else {
        // ForEach(items) { CustomRow } }` over a self-accessible (computed/@Query/stored)
        // collection. The `.isEmpty` guard host-projects (the thunk evals `(self.items).count`
        // → numeric token, `.isEmpty` == `__numtok == 0`), and the `ForEach` indexed-slots —
        // so the view LOWERS instead of leaking `items` as a free guest symbol.
        let source = """
        import SwiftUI
        import SwiftData
        struct ItemList: View {
            @Query private var items: [Item]
            var body: some View {
                VStack {
                    if items.isEmpty {
                        Text("No items")
                    } else {
                        ForEach(items) { item in
                            ItemRow(item: item)
                        }
                    }
                }
            }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source, sameFileThunk: true).first)
        XCTAssertFalse(lowered.referencesUnresolvedSymbol,
                       "the .isEmpty guard host-projects, so `items` no longer leaks: \(lowered.unresolvedSymbols)")
        XCTAssertFalse(lowered.referencesUnmarshalledInput,
                       "the ForEach over the @Query collection indexed-slots; no live unmarshalled read")
        XCTAssertTrue(lowered.hostTokens.contains { $0.kind == .number && $0.source.contains("items") && $0.source.contains("count") },
                      "items.isEmpty host-projects to a numeric (count) token: \(lowered.hostTokens)")
    }

    func testBareFreeBoolConditionStillDemotesUnchanged() throws {
        // Build-safety guard: a FREE bool condition (not a .count/.isEmpty collection guard)
        // is NOT projected — the property lever must not change non-collection-guard behavior.
        // `isLoading` (a free symbol, not guest-resolvable) keeps the view native.
        let source = """
        import SwiftUI
        struct V: View {
            var isLoading: Bool { Bool.random() }
            var body: some View {
                VStack { if isLoading { Text("…") } else { Text("done") } }
            }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source, sameFileThunk: true).first)
        // No numeric (count) token was fabricated for a non-collection free bool.
        XCTAssertFalse(lowered.hostTokens.contains { $0.kind == .number && $0.source.contains("isLoading") },
                       "a free bool condition must not be mis-projected as a collection guard")
    }

    // MARK: - Multi-site host-projection (Lever #1: Image systemName + stack spacing)

    func testImageSystemNameHostProjectsModelField() throws {
        // `Image(systemName: accent.icon)` — the systemName reads a model's String member
        // the guest can't reconstruct. It must HOST-PROJECT (route through the same string
        // host-projection Text content uses) → a `__strtok` reference, not a leaked free
        // identifier. The view lowers instead of demoting. (The #1 struct/enum-PARAM blocker.)
        let source = """
        import SwiftUI
        enum Accent: String, CaseIterable { case rp = "RP", estuary = "Estuary"
            var icon: String { "globe" } }
        struct AccentBadge: View {
            let accent: Accent
            var body: some View {
                HStack { Image(systemName: accent.icon); Text(accent.rawValue) }
            }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source, sameFileThunk: true)
            .first { $0.viewName == "AccentBadge" })
        XCTAssertFalse(lowered.referencesUnmarshalledInput,
                       "Image(systemName: accent.icon) host-projects, so accent doesn't leak")
        XCTAssertFalse(lowered.referencesUnresolvedSymbol, "no free identifier leaks: \(lowered.unresolvedSymbols)")
        // The token source is `self.accent.icon` (the computed-member-on-input path uses the
        // same `self.`-prefixed convention as the reactive-member projection — the thunk's
        // `__patchTokens()` resolves it natively over `self`). Accept either form, like the
        // struct String-field thunk-compile assertion does.
        XCTAssertEqual(lowered.hostTokens.filter {
            $0.kind == .string && ($0.source == "accent.icon" || $0.source == "self.accent.icon")
        }.count, 1, "accent.icon host-projects as a String token: \(lowered.hostTokens)")
    }

    func testImageSystemNameLiteralUnchanged() throws {
        // Build-safety guard: a string-LITERAL systemName must still emit verbatim (no token,
        // no regression) — the multi-site routing only kicks in for non-resolvable content.
        let source = """
        import SwiftUI
        struct V: View {
            var body: some View { Image(systemName: "star.fill") }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source, sameFileThunk: true).first)
        XCTAssertFalse(lowered.referencesUnmarshalledInput)
        XCTAssertEqual(lowered.hostTokens.filter { $0.kind == .string }.count, 0,
                       "a literal systemName is not host-tokenized")
    }

    func testStackSpacingDesignTokenHostProjects() throws {
        // `VStack(spacing: Theme.Radius.sm)` — a design-system numeric constant in the
        // CONTAINER spacing position must host-project (route through `numericOrToken`) → a
        // `__numtok` reference, not a leaked `Theme`. (Found by the E2E tool: emitStack
        // previously emitted `spacing:` verbatim, unlike `.padding`/`.cornerRadius`.)
        let source = """
        import SwiftUI
        enum Theme { enum Radius { static let sm: CGFloat = 8 } }
        struct Card: View {
            let title: String
            var body: some View {
                VStack(spacing: Theme.Radius.sm) { Text(title) }
            }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source, sameFileThunk: true).first)
        XCTAssertFalse(lowered.referencesUnresolvedSymbol,
                       "Theme.Radius.sm host-projects in spacing:, so Theme doesn't leak: \(lowered.unresolvedSymbols)")
        XCTAssertEqual(lowered.hostTokens.filter { $0.kind == .number }.count, 1,
                       "the design-system spacing constant host-projects as a numeric token: \(lowered.hostTokens)")
    }

    func testStructInLoweredBodyNeverBoundAsScalar() throws {
        // The never-render-wrong invariant at the codegen level: the guest emitter must
        // NEVER bind a struct input via a scalar scanner (which would yield a wrong value).
        // This holds in BOTH thunk-placement modes — the struct is never reconstructed; a
        // same-file thunk only host-resolves the STRING a field read yields (a token), it
        // never binds the struct itself as a scalar.
        let source = """
        import SwiftUI
        struct CardView: View {
            struct Profile { var name: String }
            @State private var profile = Profile(name: "Ada")
            var body: some View { Text(profile.name) }
        }
        """
        for sameFile in [false, true] {
            let lowered = try XCTUnwrap(
                BodyLowering().lowerAllViews(source: source, sameFileThunk: sameFile).first)
            let view = SwiftUIGuestEmitter.GuestView(
                viewName: lowered.viewName, guestBody: lowered.guestBody, inputs: lowered.inputs)
            let emission = try SwiftUIGuestEmitter().emit(views: [view])
            let wrapper = try XCTUnwrap(emission.files.first { $0.fileName == "_PatchSwiftUI.swift" })
            // No scalar scanner is ever applied to `profile` — in either mode.
            for scanner in ["_patchScanString(_patchInputs, \"profile\")",
                            "_patchScanInt(_patchInputs, \"profile\")",
                            "_patchScanBool(_patchInputs, \"profile\")",
                            "_patchScanDouble(_patchInputs, \"profile\")"] {
                XCTAssertFalse(wrapper.contents.contains(scanner),
                               "[\(sameFile ? "same" : "separate")-file] struct input must not be "
                               + "scalar-scanned: \(scanner)")
            }
        }
        // Separate-file: the struct-field read demotes the view (wrong-default bind never shown).
        let separate = try XCTUnwrap(
            BodyLowering().lowerAllViews(source: source, sameFileThunk: false).first)
        XCTAssertTrue(separate.referencesUnmarshalledInput,
                      "separate-file: a private struct-field read demotes the view")
    }

    func testEnumStateReadDemotes() throws {
        let source = """
        import SwiftUI
        struct StatusView: View {
            enum Status { case on, off }
            @State private var status: Status = .on
            var body: some View {
                if status == .on { Text("On") } else { Text("Off") }
            }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        let status = try XCTUnwrap(lowered.inputs.first { $0.name == "status" })
        XCTAssertEqual(status.kind, .unsupported)
        XCTAssertTrue(lowered.referencesUnmarshalledInput,
                      "a body reading an enum @State must demote")
    }

    // MARK: - END-TO-END: an [Int]/[String] input round-trips through WASM
    //
    // The body reads `scores.count` and `tags.first` — pure-structure uses of the
    // marshalled-in arrays. With a REAL array marshalled in, the guest computes the
    // REAL values (count 3, first "alpha"), not the empty default. This proves the
    // array crosses the boundary as a usable `[Int]`/`[String]`, not just a literal.

    func testArrayInputExecutesInWasm() throws {
        let compiler = SwiftWasmCompiler(
            exportedSymbols: ["view_body", "view_body__ListView", "patch_malloc", "patch_free"])
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping array round-trip")

        let source = """
        import SwiftUI
        struct ListView: View {
            let scores: [Int] = []
            let tags: [String] = []
            var body: some View {
                VStack {
                    Text("count=\\(scores.count)")
                    Text(tags.first ?? "none")
                }
            }
        }
        """
        let lowered = BodyLowering().lowerAllViews(source: source)
        // Both arrays are guest-reconstructable, so the view does NOT demote.
        XCTAssertFalse(try XCTUnwrap(lowered.first).referencesUnmarshalledInput)
        let guestViews = lowered.map {
            SwiftUIGuestEmitter.GuestView(viewName: $0.viewName, guestBody: $0.guestBody, inputs: $0.inputs)
        }
        let emission = try SwiftUIGuestEmitter().emit(views: guestViews)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftui-arr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        var sources: [URL] = []
        for f in emission.files {
            let u = tmp.appendingPathComponent(f.fileName)
            try f.contents.write(to: u, atomically: true, encoding: .utf8)
            sources.append(u)
        }
        let out = tmp.appendingPathComponent("module.swiftui.wasm")
        let result = try compiler.compile(sources: sources, outputModule: out)
        XCTAssertEqual(result.status, .success, "guest WASM compile failed:\n\(result.log)")

        // Marshal REAL arrays in — the body must compute the real count + first.
        let wasm = [UInt8](try Data(contentsOf: out))
        let runner = try Runner(wasm: wasm)
        let inputs = Data(#"{"scores":[7,8,9],"tags":["alpha","beta"]}"#.utf8)
        let outBytes = try runner.callPacked("view_body", [UInt8](inputs))
        let body = try JSONDecoder().decode(BodyEmission.self, from: Data(outBytes))
        let desc = body.root.describe()
        // Real array values used (count 3, first element), not the empty default.
        XCTAssertTrue(desc.contains("count=3"), "scores.count came from the real array: \(desc)")
        XCTAssertTrue(desc.contains("alpha"), "tags.first came from the real array: \(desc)")
    }

    // Minimal WASM runner (mirrors SwiftUILoweringTests.Runner).
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
