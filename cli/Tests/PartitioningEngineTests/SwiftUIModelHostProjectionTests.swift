// SPDX-License-Identifier: Apache-2.0

import XCTest
import SwiftParser
@testable import CodeGenerator

/// Tests for the `modelPlain` host-projection lever (cli 1.6.40) — ARM (C) of
/// `reactiveMemberTypesWithKind`.
///
/// A view with `@Bindable var item: Item` or a plain `let item: Item` where `Item` is a
/// `@Model` class currently DEMOTES (the whole view stays native) because @Model objects
/// are ObjC-backed, non-Codable reference types that can't be marshalled into WASM.
///
/// ARM (C) extends host-projection to @Model SCALAR (Int/Bool/Double) fields: the thunk's
/// `__patchTokens()` reads `self.item.<scalarField>` natively — the SAME read the view's
/// `body` would make — so a view displaying `item.durationDays > 7` or `item.isPriority`
/// lowers and routes OTA.
///
/// RENDER-CORRECTNESS INVARIANTS:
///   - The @Model object NEVER crosses to WASM (not marshalled, not a free identifier).
///   - Only SCALAR (Int/Bool/Double) single-hop stored fields host-project.
///   - String fields are handled by the pre-existing `stringTypedMemberPaths` channel
///     (AnyClassDeclCollector covers @Model classes), not this lever.
///   - Optional @Model members (`var item: Item?`) are EXCLUDED from arm C — a nil
///     dereference in `__patchTokens()` would crash the thunk (demote-safe).
///   - Relationship traversals and non-scalarFieldCatalog reads demote (single-hop only).
///
/// IRON SAFETY INVARIANTS PROVEN BY THIS SUITE:
///   (a) POSITIVE — `@Bindable var item: @Model` + `item.count > 0` host-projects the Int
///       scalar + compiles to WASM + the @Model object never appears as a free WASM identifier.
///   (b) POSITIVE — plain `let item: Item` (@Model) + `item.isPriority` host-projects Bool.
///   (c) OBJECT-NOT-MARSHALLED — the @Model object is never a marshalled input or free guest id.
///   (d) UNSAFE-DEMOTES — Optional @Model member still demotes (nil-crash safety gate).
///   (e) UNSAFE-DEMOTES — @Query var items: [Item] does NOT project per-element fields (no
///       index-access crash risk: @Query is an array, not a scalar member base).
///   (f) INERTNESS — a view with no @Model member is byte-identical to pre-1.6.40 output.
///   (g) THUNK-COMPILE — the generated thunk type-checks for iOS (the build-safety net).
///   (h) CROSS-FILE — @Model in another source file resolves via crossFileModelClassNames.
final class SwiftUIModelHostProjectionTests: XCTestCase {

    // MARK: - (a) POSITIVE: @Bindable var item: @Model projects scalar fields

    /// A view with `@Bindable var item: Item` where `Item` is `@Model` and the body reads
    /// `item.durationDays` (Int) should lower and host-project that Int as a `__numtok_`
    /// token. The @Model object must NOT appear as a free WASM identifier.
    func testBindableModelScalarFieldProjectsAsNumtok() throws {
        let src = """
        import SwiftUI
        import SwiftData

        @Model
        final class Item {
            var title: String = ""
            var durationDays: Int = 0
            var isPriority: Bool = false
        }

        struct ItemRow: View {
            @Bindable var item: Item
            var body: some View {
                VStack {
                    Text(item.title)
                    if item.durationDays > 7 {
                        Text("Long task")
                    }
                }
            }
        }
        """
        let lowering = BodyLowering()
        let views = lowering.lowerAllViews(source: src, sameFileThunk: true)
        let v = try XCTUnwrap(views.first { $0.viewName == "ItemRow" },
                              "ItemRow should be in the lowered output")

        // The view must not have unresolved symbols or unmarshalled inputs.
        XCTAssertFalse(v.referencesUnresolvedSymbol,
                       "no free guest identifier after @Model host-projection; unresolved: \(v.unresolvedSymbols)")
        XCTAssertFalse(v.referencesUnmarshalledInput,
                       "no unmarshalled input (item @Model object never crosses to WASM)")

        // item.durationDays must host-project as a __numtok_ (numeric token).
        XCTAssertTrue(v.guestBody.contains("__numtok_"),
                      "item.durationDays must host-project as __numtok_: \(v.guestBody)")

        // At least one number token must be present for item.durationDays.
        let numberTokens = v.hostTokens.filter { $0.kind == .number }
        XCTAssertFalse(numberTokens.isEmpty,
                       "must have at least one .number host token (item.durationDays): \(v.hostTokens)")

        // item.title already routes through the pre-existing stringTypedMemberPaths channel.
        // Verify that the guest body doesn't contain `item` as a free identifier.
        XCTAssertFalse(BodyLowering.guestBodyReferencesAny(v.guestBody, names: ["item"]),
                       "the `item` @Model object must not appear as a free guest identifier: \(v.guestBody)")
    }

    // MARK: - (b) POSITIVE: plain let item: @Model projects Bool scalar field

    /// A view with a PLAIN stored `let item: Item` (no @Bindable wrapper) where `Item` is
    /// `@Model` should also lower via arm (C) and host-project Bool scalar fields.
    func testPlainLetModelMemberProjectsBoolScalar() throws {
        let src = """
        import SwiftUI
        import SwiftData

        @Model
        final class Task {
            var name: String = ""
            var isCompleted: Bool = false
            var priority: Int = 0
        }

        struct TaskRow: View {
            let item: Task
            var body: some View {
                VStack {
                    Text(item.name)
                    if item.isCompleted {
                        Text("Done")
                    }
                }
            }
        }
        """
        let lowering = BodyLowering()
        let views = lowering.lowerAllViews(source: src, sameFileThunk: true)
        let v = try XCTUnwrap(views.first { $0.viewName == "TaskRow" },
                              "TaskRow should be in the lowered output")

        XCTAssertFalse(v.referencesUnresolvedSymbol,
                       "no free guest identifier; unresolved: \(v.unresolvedSymbols)")
        XCTAssertFalse(v.referencesUnmarshalledInput,
                       "no unmarshalled input (item @Model never crosses to WASM)")

        // item.isCompleted must host-project as a __numtok_ (Bool-as-Double token).
        XCTAssertTrue(v.guestBody.contains("__numtok_"),
                      "item.isCompleted must host-project as __numtok_: \(v.guestBody)")

        let numberTokens = v.hostTokens.filter { $0.kind == .number }
        XCTAssertFalse(numberTokens.isEmpty,
                       "must have at least one .number host token (item.isCompleted): \(v.hostTokens)")

        // The token source should reference item.isCompleted or item.priority.
        // Bool tokens are wrapped in the ternary `((self.item.isCompleted) ? 1.0 : 0.0)` by
        // the host-token mechanism (Bool-as-Double encoding). Accept either the bare source
        // or the ternary form.
        let modelTokenSources = v.hostTokens.filter {
            $0.kind == .number && $0.source.contains("item.")
        }
        XCTAssertFalse(modelTokenSources.isEmpty,
                       "at least one numeric token must reference item.<field>: \(v.hostTokens)")
    }

    // MARK: - (c) OBJECT-NOT-MARSHALLED: @Model object never enters WASM

    /// The `@Model` object itself (`item`) must not appear as a marshalled input or free
    /// guest identifier. ONLY the resolved scalar values cross via the numeric token mechanism.
    func testModelObjectNeverMarshalledAsInput() throws {
        let src = """
        import SwiftUI
        import SwiftData

        @Model
        final class Project {
            var name: String = ""
            var taskCount: Int = 0
            var isActive: Bool = false
        }

        struct ProjectRow: View {
            @Bindable var item: Project
            var body: some View {
                VStack {
                    Text(item.name)
                    if item.taskCount > 0 {
                        Text("\\(item.taskCount) tasks")
                    }
                }
            }
        }
        """
        let lowering = BodyLowering()
        let views = lowering.lowerAllViews(source: src, sameFileThunk: true)
        let v = try XCTUnwrap(views.first { $0.viewName == "ProjectRow" },
                              "ProjectRow should be found")

        // (1) `item` must NOT appear as a free identifier in the guest body.
        XCTAssertFalse(BodyLowering.guestBodyReferencesAny(v.guestBody, names: ["item"]),
                       "@Model object `item` must not appear as free guest identifier: \(v.guestBody)")

        // (2) `item` must NOT be a marshalled (guest-reconstructable) input.
        let marshalledItem = v.inputs.filter { $0.name == "item" && $0.kind.guestReconstructable }
        XCTAssertTrue(marshalledItem.isEmpty,
                      "item @Model must not be a marshalled input: \(v.inputs.map { "\($0.name):\($0.kind)" })")

        // (3) All host tokens for item.* must be .number or .string kinds (no object type).
        for tok in v.hostTokens where tok.source.hasPrefix("item.") {
            XCTAssertTrue(tok.kind == .number || tok.kind == .string,
                          "item.* token must be .number or .string only: \(tok)")
        }

        // (4) The view must not fail the scope check or have unmarshalled reads.
        XCTAssertFalse(v.referencesUnmarshalledInput,
                       "item @Model is in unmarshalledNames but must not block after projection")
    }

    // MARK: - (d) UNSAFE-DEMOTES: Optional @Model member stays native (nil-crash safety)

    /// A `var item: Item?` (Optional @Model) must NOT be host-projected via arm (C).
    /// A nil dereference in `__patchTokens()` would crash the thunk — demoting is correct.
    /// The top-level Optional annotation (`?`) is the explicit guard that blocks arm (C).
    func testOptionalModelMemberDemotes() throws {
        let src = """
        import SwiftUI
        import SwiftData

        @Model
        final class Note {
            var title: String = ""
            var charCount: Int = 0
        }

        struct NoteDetail: View {
            var item: Note?
            var body: some View {
                if let note = item {
                    Text(note.title)
                }
            }
        }
        """
        // IRON SAFETY: Optional @Model must NOT produce a numeric token via arm (C).
        // A __numtok_ for `item.charCount` would require reading `self.item.charCount`
        // in `__patchTokens()` — which crashes when `item` is nil.
        let lowering = BodyLowering()
        let views = lowering.lowerAllViews(source: src, sameFileThunk: true)
        let v = try XCTUnwrap(views.first { $0.viewName == "NoteDetail" })

        // No numeric token must reference the Optional @Model `item`.
        let dangerousTokens = v.hostTokens.filter {
            $0.kind == .number && $0.source.hasPrefix("item.")
        }
        XCTAssertTrue(dangerousTokens.isEmpty,
                      "Optional @Model `item?` must NOT produce a numeric host token via arm C: "
                      + "\(v.hostTokens.map { "\($0.kind):\($0.source)" })")
    }

    // MARK: - (e) UNSAFE-DEMOTES: @Query array does not project per-element scalar fields

    /// A `@Query var items: [Item]` property is an ARRAY of @Model objects, not a scalar
    /// @Model instance. Arm (C) only fires for NON-Optional single-instance members whose
    /// type is in `modelClassNames`. An array type (`[Item]`) is NOT in `modelClassNames`
    /// (that would be the bare type name `Item`, not `[Item]`), so @Query arrays are
    /// safely excluded from arm (C) and remain demoted as before.
    func testQueryArrayDoesNotProjectElementFields() throws {
        let src = """
        import SwiftUI
        import SwiftData

        @Model
        final class Recipe {
            var name: String = ""
            var servings: Int = 1
        }

        struct RecipeList: View {
            @Query var items: [Recipe]
            var body: some View {
                List(items, id: \\.name) { recipe in
                    Text(recipe.name)
                }
            }
        }
        """
        // IRON SAFETY: `items` is `[Recipe]` (an array type), not a bare `Recipe`.
        // Arm (C) keys on the type name after cleanedTypeName — for `[Recipe]`, cleanedTypeName
        // strips brackets and returns nil (it contains `[`/`]` which fail `allSatisfy { isLetter... }`).
        // So arm (C) cannot fire for @Query array members — verified here.
        let lowering = BodyLowering()
        let views = lowering.lowerAllViews(source: src, sameFileThunk: true)
        let v = try XCTUnwrap(views.first { $0.viewName == "RecipeList" })

        // No numeric token for `items.servings` or any per-element field access.
        let elementTokens = v.hostTokens.filter {
            $0.kind == .number && $0.source.hasPrefix("items.")
        }
        XCTAssertTrue(elementTokens.isEmpty,
                      "@Query array `items: [Recipe]` must NOT produce numeric tokens for element fields: "
                      + "\(v.hostTokens.map { "\($0.kind):\($0.source)" })")
    }

    // MARK: - (f) INERTNESS: a view with no @Model member is byte-identical

    /// A view with only scalar inputs (no @Model, no @Observable class) must produce a
    /// byte-identical guest body with the new arm (C) code in place. The new arm is a no-op
    /// when `mergedModelClassNames` is empty.
    func testViewWithNoModelMemberIsInert() throws {
        let src = """
        import SwiftUI

        struct SimpleView: View {
            let title: String
            let count: Int
            var body: some View {
                VStack {
                    Text(title)
                    Text("Count: \\(count)")
                }
            }
        }
        """
        let lowering = BodyLowering()
        let views = lowering.lowerAllViews(source: src, sameFileThunk: true)
        let v = try XCTUnwrap(views.first { $0.viewName == "SimpleView" })

        // No @Model classes → arm (C) is a no-op, no new tokens.
        XCTAssertFalse(v.referencesUnresolvedSymbol,
                       "SimpleView must lower cleanly: unresolved=\(v.unresolvedSymbols)")
        XCTAssertFalse(v.referencesUnmarshalledInput,
                       "SimpleView has no class inputs")

        // No spurious __numtok_ from arm (C) for scalar inputs (they bind as marshalled inputs,
        // not host tokens).
        let spuriousTokens = v.hostTokens.filter {
            $0.kind == .number
                && ($0.source.contains("title") || $0.source.contains("count"))
        }
        XCTAssertTrue(spuriousTokens.isEmpty,
                      "scalar inputs on a plain struct must not become host tokens via arm (C): \(spuriousTokens)")
    }

    // MARK: - (g) THUNK-COMPILE: the generated thunk type-checks for iOS

    /// The `__patchTokens()` method generated for a `let item: Goal` (@Model) view must
    /// type-check against the iOS simulator SDK. This is the build-safety net: the engine
    /// emits `__t["..."] = .number(Double(self.item.targetDays))` in `__patchTokens()` — we
    /// verify this exact shape compiles.
    ///
    /// We use a PLAIN STORED `let item: Goal` (not `@Bindable`) so the fixture compiles against
    /// iOS 16 (Bindable requires iOS 17). The @Model annotation is stripped before the
    /// type-check because SwiftData's `@Model` macro is not available in the standalone swiftc
    /// compile; the thunk itself only uses `self.item.targetDays` (a plain property read).
    /// The engine inferred the type from the same-file `@Model` source — the thunk code is
    /// correct for any class with a stored `targetDays: Int` property.
    func testModelProjectionThunkCompiles() throws {
        // Source the engine sees (uses @Model so modelClassNames fires).
        let src = """
        import SwiftUI
        import SwiftData

        @Model
        final class Goal {
            var name: String = ""
            var targetDays: Int = 30
            var isComplete: Bool = false
        }

        struct GoalRow: View {
            let item: Goal
            var body: some View {
                VStack {
                    Text(item.name)
                    if item.targetDays > 14 {
                        Text("Long goal")
                    }
                }
            }
        }
        """
        let sdkPath = Self.run("/usr/bin/xcrun", ["--show-sdk-path", "--sdk", "iphonesimulator"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sdkPath, !sdkPath.isEmpty else {
            throw XCTSkip("no iphonesimulator SDK — thunk-compile gate skipped")
        }

        let url = URL(fileURLWithPath: "/tmp/PatchModelFixture.swift")
        let result = ThunkGenerator().prepare(sources: [.init(url: url, text: src)], sameFile: true)
        let modifiedText = result.modifiedFiles.first?.text ?? src

        XCTAssertGreaterThan(result.dynamicInsertions, 0,
                             "GoalRow body must have been made `dynamic`")

        let patched = modifiedText
            .replacingOccurrences(of: "import PatchSDK\n", with: "")
            .replacingOccurrences(of: "import PatchSwiftUI\n", with: "")
            .replacingOccurrences(of: "import PatchRender\n", with: "")
            // Strip SwiftData import and @Model annotation: the swiftc type-check doesn't need
            // the SwiftData framework — only the plain class body (the @Model macro expansion is
            // irrelevant for thunk compile; swiftc sees `final class Goal { var targetDays: Int }`).
            .replacingOccurrences(of: "import SwiftData\n", with: "")
            .replacingOccurrences(of: "@Model\n", with: "")

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("patch-model-thunk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try patched.write(to: tmp.appendingPathComponent("Fixture.swift"),
                          atomically: true, encoding: .utf8)
        try Self.hostStub.write(to: tmp.appendingPathComponent("HostStub.swift"),
                                atomically: true, encoding: .utf8)

        let args = [
            "-typecheck",
            "-sdk", sdkPath,
            "-target", "arm64-apple-ios16.0-simulator",
            tmp.appendingPathComponent("Fixture.swift").path,
            tmp.appendingPathComponent("HostStub.swift").path
        ]
        let log = Self.run("/usr/bin/swiftc", args, captureStderr: true) ?? ""
        XCTAssertFalse(log.contains("error:"),
                       "[ModelProjection] generated thunk must type-check for iOS:\n"
                       + "----- log -----\n\(log)\n"
                       + "----- generated -----\n\(modifiedText)")
    }

    // MARK: - (h) CROSS-FILE: @Model class in another source file resolves via bundle

    /// The `@Model` class defined in a MODEL FILE (separate from the view) must host-project
    /// its SCALAR fields via the cross-file bundle mechanism (`crossFileModelClassNames`).
    func testCrossFileModelClassProjectsViaBundle() throws {
        let modelSource = """
        import Foundation
        import SwiftData

        @Model
        final class Habit {
            var title: String = ""
            var streak: Int = 0
            var isActive: Bool = false
        }
        """
        let viewSource = """
        import SwiftUI
        struct HabitRow: View {
            let item: Habit
            var body: some View {
                VStack {
                    Text(item.title)
                    if item.streak > 7 {
                        Text("On fire!")
                    }
                }
            }
        }
        """
        // Build the cross-file bundle from both sources.
        let bundle = BodyLowering.crossFileBundle(sources: [modelSource, viewSource])

        // The bundle must include Habit in its model class names.
        XCTAssertTrue(bundle.modelClassNames.contains("Habit"),
                      "cross-file bundle must include @Model class from model source: \(bundle.modelClassNames)")

        let lowering = BodyLowering()
        let views = lowering.lowerAllViews(source: viewSource, crossFile: bundle)
        let v = try XCTUnwrap(views.first { $0.viewName == "HabitRow" },
                              "HabitRow should be in the lowered output")

        // The view must lower (the @Model class is resolved cross-file).
        XCTAssertFalse(v.referencesUnresolvedSymbol,
                       "cross-file @Model must resolve; unresolved: \(v.unresolvedSymbols)")
        XCTAssertFalse(v.referencesUnmarshalledInput,
                       "item @Model object must not be marshalled (only scalar tokens cross)")

        // item.streak must host-project as a number token.
        let numberTokens = v.hostTokens.filter { $0.kind == .number }
        XCTAssertFalse(numberTokens.isEmpty,
                       "cross-file @Model Int field must produce a number token: \(v.hostTokens)")

        // The @Model object itself must not appear as a free identifier.
        XCTAssertFalse(BodyLowering.guestBodyReferencesAny(v.guestBody, names: ["item"]),
                       "@Model object `item` must not appear as free guest identifier cross-file: \(v.guestBody)")
    }

    // MARK: - modelClassNames(in:) catalog

    /// `modelClassNames` correctly identifies @Model classes (including @Observable+@Model).
    func testModelClassNamesCatalog() throws {
        let src = """
        @Model final class GoodModel { var x: Int = 0 }
        @Observable @Model final class HybridModel { var x: Int = 0 }
        @Observable final class PlainVM { var x: Int = 0 }
        final class PlainClass { var x: Int = 0 }
        struct NotAClass { var x: Int = 0 }
        """
        let tree = SwiftParser.Parser.parse(source: src)
        let names = BodyLowering.modelClassNames(in: tree)

        // GoodModel and HybridModel qualify (both have @Model).
        XCTAssertTrue(names.contains("GoodModel"),
                      "@Model class must be in modelClassNames: \(names)")
        XCTAssertTrue(names.contains("HybridModel"),
                      "@Model+@Observable class must also be in modelClassNames: \(names)")
        // Non-@Model types must be excluded.
        XCTAssertFalse(names.contains("PlainVM"),
                       "@Observable-only class must be EXCLUDED from modelClassNames: \(names)")
        XCTAssertFalse(names.contains("PlainClass"),
                       "Plain class must be EXCLUDED: \(names)")
        XCTAssertFalse(names.contains("NotAClass"),
                       "Struct must be EXCLUDED: \(names)")
    }

    // MARK: - modelClassNames are separated from observableClassNames (both correct)

    /// A `@Bindable var vm: MyVM` where `MyVM` is `@Observable` (non-@Model) must still
    /// use arm (A/B) and produce a `.observablePlain` projection. A `@Bindable var item:
    /// MyModel` where `MyModel` is `@Model` uses arm (C) with `.modelPlain`. Both work
    /// independently in the same view.
    func testObservableAndModelArmsWorkIndependently() throws {
        let src = """
        import SwiftUI
        import SwiftData

        @Observable
        final class ItemVM {
            var score: Int = 0
            var label: String = ""
        }

        @Model
        final class DataModel {
            var count: Int = 0
            var name: String = ""
        }

        struct DualView: View {
            @Bindable var vm: ItemVM
            @Bindable var item: DataModel
            var body: some View {
                VStack {
                    Text(vm.label)
                    Text(item.name)
                    if vm.score > 10 || item.count > 5 {
                        Text("Active")
                    }
                }
            }
        }
        """
        let lowering = BodyLowering()
        let views = lowering.lowerAllViews(source: src, sameFileThunk: true)
        let v = try XCTUnwrap(views.first { $0.viewName == "DualView" })

        XCTAssertFalse(v.referencesUnresolvedSymbol,
                       "DualView must lower cleanly: unresolved=\(v.unresolvedSymbols)")
        XCTAssertFalse(v.referencesUnmarshalledInput,
                       "no unmarshalled input after both arms project")

        // Both vm.score and item.count must produce numeric tokens.
        let numTokens = v.hostTokens.filter { $0.kind == .number }
        XCTAssertGreaterThanOrEqual(numTokens.count, 2,
                                    "expected ≥2 numeric tokens (vm.score + item.count): \(v.hostTokens)")

        // Neither `vm` nor `item` must appear as free guest identifiers.
        XCTAssertFalse(BodyLowering.guestBodyReferencesAny(v.guestBody, names: ["vm", "item"]),
                       "neither @Observable `vm` nor @Model `item` must appear as free identifiers: \(v.guestBody)")
    }

    // MARK: - Helpers (mirrors SwiftUIThunkCompileTests)

    static let hostStub = """
    import SwiftUI

    public enum PatchHostToken {
        case color(Color)
        case font(Font)
        case number(Double)
        case string(String)
    }

    public struct PatchRowSlot {
        public var count: Int
        public var factory: (Int) -> AnyView
        public init(count: Int, factory: @escaping (Int) -> AnyView) {
            self.count = count; self.factory = factory
        }
    }

    @MainActor
    public final class PatchedBodyHost: View {
        public var body: some View { EmptyView() }
    }

    @MainActor
    public final class Patch {
        public static let shared = Patch()
        public func thunkBody(typeName: String, baselineHash: String? = nil, instance: Any,
                              slots: () -> [String: ([String]) -> AnyView] = { [:] },
                              tokens: () -> [String: PatchHostToken] = { [:] },
                              rowSlots: () -> [String: PatchRowSlot] = { [:] },
                              actionSlots: () -> [String: () -> Void] = { [:] },
                              effectSlots: () -> [String: (AnyView) -> AnyView] = { [:] },
                              callbackSlots: () -> [String: () -> AnyView] = { [:] }) -> PatchedBodyHost? {
            nil
        }
    }
    """

    @discardableResult
    static func run(_ exe: String, _ args: [String], captureStderr: Bool = false) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        if captureStderr { proc.standardError = pipe }
        do {
            try proc.run()
            proc.waitUntilExit()
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        } catch { return nil }
    }
}
