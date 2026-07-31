// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
import SwiftParser
import SwiftSyntax
@testable import CodeGenerator
import ViewNodeIR

/// CROSS-FILE SAME-NAME TYPE AMBIGUITY (soundness) + the smaller catalog/eligibility bugs.
/// =======================================================================================
/// When two files declare a type with the SAME name but DIFFERENT field shapes, a file whose
/// definition yields NO entry for a given host-projection catalog (its field is a non-String
/// for the String catalog, a non-scalar for the scalar catalog, a non-collection for the
/// collection-guard catalog, an un-reconstructable element for the reactive-collection SHAPE
/// catalog) used to EVADE the per-catalog ambiguity drop (which only fired when BOTH files
/// contributed a conflicting entry). The other file's entry was then trusted and a token /
/// marshalling was emitted that won't compile (or wrong-renders) in the dev's app.
///
/// The fix tracks every type NAME declared in 2+ files (independent of catalog membership)
/// and DROPS an ambiguous type from every cross-file catalog. These tests pin that contract
/// across all the same-name catalogs (R2-#17..#20, #59, #60, #61), plus the field-order
/// insensitivity (#109/#110), the `Theme.String` mis-typing (#108), and the generic-`where`
/// view eligibility match (#62).
final class SwiftUICrossFileCatalogSafetyTests: XCTestCase {

    // MARK: - The declared-in-2+-files ambiguity set (the shared root)

    func testAmbiguousNamesAcrossFiles() {
        let a = "struct Item { var name: String }"
        let b = "struct Item { var name: AttributedString }\nstruct Unique { var x: String }"
        let amb = BodyLowering.crossFileAmbiguousTypeNames(sources: [a, b])
        XCTAssertTrue(amb.contains("Item"), "Item is declared in both files → ambiguous")
        XCTAssertFalse(amb.contains("Unique"), "Unique is only in one file")
    }

    func testAmbiguousNamesSpanStructClassEnum() {
        // The set is keyed on the NAME across struct/class/enum kinds, including nested decls.
        let a = "class Engine { var level: Int }"
        let b = "enum Engine { case a, b }"
        let amb = BodyLowering.crossFileAmbiguousTypeNames(sources: [a, b])
        XCTAssertTrue(amb.contains("Engine"))
    }

    // MARK: - R2-#19 / #60: cross-file String / enum-rawValue catalog

    func testStringCatalogDropsSameNameWhenOneFileIsNonString() {
        // File A: `Item.name: String`. File B: `Item.name: AttributedString` (NO String entry).
        // The merge must NOT trust File A's [name:String] for an Item used in File B.
        let a = "struct Item { var name: String }"
        let b = "struct Item { var name: AttributedString }"
        let cat = BodyLowering.crossFileCatalogs(sources: [a, b]).stringFields
        XCTAssertNil(cat["Item"], "ambiguous same-name Item must be dropped from the String catalog")
    }

    func testEnumRawValueDropsWhenOneFileIsNotStringRaw() {
        // File A: String-raw enum (→ rawValue:String). File B: an enum with an associated value
        // (not String-raw → no rawValue field). The cross-file String catalog must drop Status.
        let a = "enum Status: String { case a, b }"
        let b = "enum Status { case a(Int), b }"
        let cat = BodyLowering.crossFileCatalogs(sources: [a, b]).stringFields
        XCTAssertNil(cat["Status"], "ambiguous Status must not leak a rawValue:String entry")
    }

    func testStringCatalogKeepsUniqueType() {
        // A uniquely-named type still resolves cross-file (no over-drop / coverage loss).
        let a = "struct Card { var title: String; var color: Color }"
        let b = "struct OtherThing { var z: Int }"
        let cat = BodyLowering.crossFileCatalogs(sources: [a, b]).stringFields
        XCTAssertEqual(cat["Card"]?.first?.name, "title",
                       "a unique type still host-projects its String field cross-file")
    }

    // MARK: - R2-#20 / #59: cross-file reactive SCALAR-field catalog

    func testScalarCatalogDropsSameNameWhenOneFileIsNonScalar() {
        // File A: `VM.count: Int`. File B: `VM.count: String` (no scalar entry — String isn't a
        // scalarKind here). The cross-file scalar catalog must not host-project vm.count as .int.
        let a = "class VM { var count: Int = 0 }"
        let b = "class VM { var count: String = \"\" }"
        let cat = BodyLowering.crossFileReactiveCatalogs(sources: [a, b]).scalarFields
        XCTAssertNil(cat["VM"], "ambiguous same-name VM must be dropped from the scalar catalog")
    }

    func testScalarCatalogDropsWhenOneFileFieldIsAStruct() {
        let a = "class Engine { var level: Int = 0 }"
        let b = "class Engine { var level: SomeStruct }\nstruct SomeStruct { var x: Int }"
        let cat = BodyLowering.crossFileReactiveCatalogs(sources: [a, b]).scalarFields
        XCTAssertNil(cat["Engine"], "Engine's level differs in shape across files → dropped")
    }

    // MARK: - R2-#18: cross-file collection-guard catalog

    func testCollectionCatalogDropsSameNameWhenOneFileIsNonCollection() {
        // File A: `Bag.items: [Thing]` (a collection). File B: `Bag.items: Int` (no collection
        // entry). Host-projecting `(self.bag.items).count` against File A would not compile on
        // an Int. The cross-file collection catalog must drop Bag.
        let a = "class Bag { var items: [Thing] = [] }\nstruct Thing { var n: Int }"
        let b = "class Bag { var items: Int = 0 }"
        let cat = BodyLowering.crossFileReactiveCatalogs(sources: [a, b]).collectionFields
        XCTAssertNil(cat["Bag"], "ambiguous same-name Bag must be dropped from the collection catalog")
    }

    // MARK: - R2-#17 / #61: cross-file reactive-collection SHAPE catalog

    func testReactiveShapeDropsSameNameElementStruct() {
        // File A: a flat `Note`. File B: a `Note` with an AttributedString field (NO flatStruct
        // entry) plus a Store whose `notes: [Note]`. The element shape must NOT resolve against
        // File A's flat Note (wrong-render). Store keeps an empty/absent entry → ForEach demotes.
        let a = "struct Note { let text: String }"
        let b = """
        struct Note { let text: AttributedString; let n: Int }
        @Observable class StoreB { var notes: [Note] = [] }
        """
        let cat = BodyLowering.crossFileReactiveCollectionShapeCatalog(sources: [a, b])
        XCTAssertNil(cat["StoreB"]?.first(where: { $0.name == "notes" }),
                     "StoreB.notes must not marshal File A's flat Note shape (ambiguous element)")
    }

    func testReactiveShapeDropsSameNameModelType() {
        // The reactive MODEL type itself is same-named across files: drop it outright.
        let a = """
        struct Item { var name: String; var score: Int }
        @Observable class Store { var items: [Item] = [] }
        """
        let b = """
        struct Item { var name: String; var color: Color }
        @Observable class Store { var items: [Item] = [] }
        """
        let cat = BodyLowering.crossFileReactiveCollectionShapeCatalog(sources: [a, b])
        XCTAssertNil(cat["Store"], "same-name Store (with same-name element Item) must be dropped")
    }

    func testReactiveShapeKeepsUniqueModel() {
        // A unique model with a unique flat element still resolves (no over-drop).
        let a = """
        struct Player { let id: Int; let name: String }
        @Observable class Roster { var players: [Player] = [] }
        """
        let b = "struct Unrelated { var z: Int }"
        let cat = BodyLowering.crossFileReactiveCollectionShapeCatalog(sources: [a, b])
        let players = cat["Roster"]?.first(where: { $0.name == "players" })
        XCTAssertNotNil(players, "a unique reactive model still marshals its collection")
    }

    // MARK: - R2-#109 / #110: field-ORDER insensitivity (no false ambiguity drop)

    func testStructFieldOrderDoesNotCauseFalseDrop() {
        // Semantically-identical structs with members reordered must NOT be treated as ambiguous.
        let a = "struct Item { var name: String; var title: String }"
        let b = "struct Item { var title: String; var name: String }"
        let cat = BodyLowering.crossFileCatalogs(sources: [a, b]).stringFields
        // NOTE: declared in 2 files → the conservative declared-in-2+-files drop fires regardless.
        // The order-insensitivity matters when the SAME single file's catalog is merged with an
        // identically-shaped copy; assert the structural-fields catalog itself is order-insensitive.
        let fa = BodyLowering.flatStructCatalog(in: Parser.parse(source: a))["Item"]!
        let fb = BodyLowering.flatStructCatalog(in: Parser.parse(source: b))["Item"]!
        var dst: [String: [BodyLowering.StructField]] = [:]
        var dropped = Set<String>()
        BodyLowering.mergeStructFieldCatalog(["Item": fa], into: &dst, &dropped)
        BodyLowering.mergeStructFieldCatalog(["Item": fb], into: &dst, &dropped)
        XCTAssertNotNil(dst["Item"], "a member reorder of an identical type must NOT drop it")
        XCTAssertFalse(dropped.contains("Item"))
        _ = cat
    }

    func testGenuineShapeConflictStillDrops() {
        // The order-insensitive merge must STILL drop a genuine field-set disagreement.
        let fa = [BodyLowering.StructField(name: "name", kind: .string)]
        let fb = [BodyLowering.StructField(name: "title", kind: .string)]
        var dst: [String: [BodyLowering.StructField]] = [:]
        var dropped = Set<String>()
        BodyLowering.mergeStructFieldCatalog(["X": fa], into: &dst, &dropped)
        BodyLowering.mergeStructFieldCatalog(["X": fb], into: &dst, &dropped)
        XCTAssertNil(dst["X"], "a genuine field-set disagreement still drops the name")
        XCTAssertTrue(dropped.contains("X"))
    }

    // MARK: - R2-#108: `Theme.String` (a nested type named String) is NOT Swift.String

    func testNestedTypeNamedStringIsNotProjected() {
        XCTAssertTrue(BodyLowering.isBareSwiftString("String"))
        XCTAssertTrue(BodyLowering.isBareSwiftString("Swift.String"))
        XCTAssertFalse(BodyLowering.isBareSwiftString("Theme.String"))
        XCTAssertFalse(BodyLowering.isBareSwiftString("Foo.Bar.String"))
        let src = "struct Page { var title: Theme.String; var name: String }"
        let cat = BodyLowering.hostProjectableStringFieldCatalog(in: Parser.parse(source: src))
        let fields = cat["Page"] ?? []
        XCTAssertTrue(fields.contains(where: { $0.name == "name" }),
                      "a bare String stored field is still host-projected")
        XCTAssertFalse(fields.contains(where: { $0.name == "title" }),
                       "a Theme.String field must NOT be mis-typed as Swift.String")
    }

    func testQualifiedSwiftStringIsProjected() {
        let src = "struct Page { var title: Swift.String }"
        let cat = BodyLowering.hostProjectableStringFieldCatalog(in: Parser.parse(source: src))
        XCTAssertEqual(cat["Page"]?.first?.name, "title",
                       "an explicitly-qualified Swift.String IS Swift.String")
    }

    // MARK: - R2-#62: a generic View with a `where` clause is excluded from lowering

    func testGenericWhereViewIsNotLowered() {
        // ThunkGenerator.discover excludes `struct Row<T>: View where T: …` (no thunk generated),
        // so the engine must NOT lower + ship it thunkSafe (that would false-stable / render native).
        let src = """
        import SwiftUI
        struct Row<T>: View where T: Identifiable {
            let item: T
            var body: some View { Text("row").padding(6) }
        }
        struct Plain: View {
            var body: some View { Text("plain") }
        }
        """
        let names = Set(BodyLowering().lowerAllViews(source: src).map(\.viewName))
        XCTAssertFalse(names.contains("Row"),
                       "a generic View with a where clause must be excluded from lowering (R2-#62)")
        XCTAssertTrue(names.contains("Plain"),
                      "a plain View still lowers (no over-exclusion)")
    }

    func testGenericWithoutWhereStillLowers() {
        // Only generic+where is excluded; a generic view with NO where clause is unaffected.
        let src = """
        import SwiftUI
        struct Box<T>: View {
            var body: some View { Text("box") }
        }
        """
        let names = Set(BodyLowering().lowerAllViews(source: src).map(\.viewName))
        XCTAssertTrue(names.contains("Box"),
                      "a generic View WITHOUT a where clause is NOT excluded")
    }

    // MARK: - viewbuilder-child container lift (hasPatchableLoweredElement includes hasLoweredContainerNode)

    /// A `@ViewBuilder`-child container (`struct Card<Content: View>: View`) whose body
    /// wraps the caller-supplied child in a `VStack` chrome HAS genuinely OTA-patchable
    /// structure. The VStack IS lowered (it IS a container node), so `hasLoweredContainerNode`
    /// returns true, which makes `hasPatchableLoweredElement` true, allowing the BuildPipeline
    /// to mark it `thunkSafe`. The `content` opaque leaf is slotable (it references no
    /// body-local or inaccessible member — `Content: View` is a stored property of `self`).
    func testViewBuilderChildContainerChromeIsThunkSafe() {
        let src = """
        import SwiftUI
        struct Card<Content: View>: View {
            let content: Content
            var body: some View {
                VStack {
                    content
                }
            }
        }
        """
        let views = BodyLowering().lowerAllViews(source: src)
        let card = views.first(where: { $0.viewName == "Card" })
        XCTAssertNotNil(card, "Card<Content: View> must be lowered (no where clause)")
        if let card = card {
            XCTAssertTrue(card.report.hasLoweredContainerNode,
                "VStack in the body IS a lowered container node")
            XCTAssertTrue(card.report.hasPatchableLoweredElement,
                "VStack chrome makes hasPatchableLoweredElement true → auto-route eligible")
            XCTAssertFalse(card.referencesUnmarshalledInput,
                "`content` only appears in an opaque label string, not a live guest ref")
        }
    }

    /// NEAR-MISS: a pure pass-through (`struct Passthrough<Content: View>`) whose body is
    /// ONLY `content` — no container, no modifiers. The body is entirely an opaque slot
    /// with nothing lowered, so `hasPatchableLoweredElement` is false and the BuildPipeline
    /// rightly does NOT mark it thunkSafe (there's nothing OTA-patchable to gain).
    func testViewBuilderPurePassthroughNotThunkSafe() {
        let src = """
        import SwiftUI
        struct Passthrough<Content: View>: View {
            let content: Content
            var body: some View {
                content
            }
        }
        """
        let views = BodyLowering().lowerAllViews(source: src)
        let pt = views.first(where: { $0.viewName == "Passthrough" })
        XCTAssertNotNil(pt, "Passthrough must be lowered (no where clause)")
        if let pt = pt {
            XCTAssertFalse(pt.report.hasLoweredContainerNode,
                "pure passthrough has no lowered container")
            XCTAssertFalse(pt.report.hasLoweredContentNode,
                "pure passthrough has no lowered content node")
            XCTAssertFalse(pt.report.hasPatchableLoweredElement,
                "pure passthrough has no patchable element → BuildPipeline keeps it native")
        }
    }

    // MARK: - Cross-file computed-member host-projection

    /// THE FEATURE: a view in file A has `let size: BadgeSize` (a view param) whose type
    /// `BadgeSize` is defined in file B (a separate file, e.g. `Theme.swift`). When
    /// `BadgeSize` has a computed `var iconSize: CGFloat`, `size.iconSize` in the body
    /// should host-project as a numeric token (the thunk evaluates `self.size.iconSize`
    /// natively). Before this fix, `computedScalarFontMemberCatalog` was per-file only —
    /// a cross-file type was invisible, so the view demoted. After: the cross-file computed
    /// member catalog is built + merged, unlocking the pattern.
    func testCrossFileComputedMemberCatalogBuildsAndMerges() {
        // A shared design file with a BadgeSize enum and computed CGFloat members.
        let sharedFile = """
        import SwiftUI
        enum BadgeSize {
            case small, large
            var iconSize: CGFloat {
                switch self { case .small: return 16; case .large: return 32 }
            }
            var padding: CGFloat {
                switch self { case .small: return 4; case .large: return 8 }
            }
        }
        """
        let cat = BodyLowering.crossFileComputedMemberCatalog(sources: [sharedFile])
        XCTAssertNotNil(cat["BadgeSize"],
                        "BadgeSize's computed members must be cataloged cross-file")
        XCTAssertEqual(cat["BadgeSize"]?["iconSize"], .number,
                       "iconSize: CGFloat must be a .number token")
        XCTAssertEqual(cat["BadgeSize"]?["padding"], .number,
                       "padding: CGFloat must be a .number token")
    }

    /// The cross-file computed-member catalog must DROP a type defined in 2+ files
    /// (same ambiguity rule as the other catalogs — a view using a same-name type
    /// from a different file must not wrongly host-project a member).
    func testCrossFileComputedMemberCatalogDropsAmbiguous() {
        let fileA = "enum BadgeSize { case a; var iconSize: CGFloat { 16 } }"
        let fileB = "enum BadgeSize { case b; var iconSize: CGFloat { 32 } }"
        let cat = BodyLowering.crossFileComputedMemberCatalog(sources: [fileA, fileB])
        XCTAssertNil(cat["BadgeSize"],
                     "a type declared in 2+ files must be dropped from the computed-member catalog")
    }

    /// THE END-TO-END LIFT: a view that reads `size.iconSize` where `BadgeSize` is defined
    /// in a SEPARATE source file lowers via the cross-file computed-member path. With a
    /// same-file definition the lowering already worked (existing test coverage); this test
    /// proves the cross-file case now works too.
    func testCrossFileComputedMemberLowersView() {
        // File A: the view (no BadgeSize definition here).
        let viewFile = """
        import SwiftUI
        struct StreakBadge: View {
            let count: Int
            let size: BadgeSize
            var body: some View {
                HStack(spacing: 6) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: size.iconSize))
                    Text("\\(count)")
                }
            }
        }
        """
        // File B: the shared type definition (computed CGFloat member).
        let sharedFile = """
        enum BadgeSize {
            case small, large
            var iconSize: CGFloat {
                switch self { case .small: return 16; case .large: return 32 }
            }
        }
        """
        let bundle = BodyLowering.crossFileBundle(sources: [viewFile, sharedFile])
        XCTAssertNotNil(bundle.computedMembers["BadgeSize"],
                        "BadgeSize's computed members must be in the cross-file bundle")
        let views = BodyLowering().lowerAllViews(source: viewFile, crossFile: bundle)
        guard let v = views.first(where: { $0.viewName == "StreakBadge" }) else {
            XCTFail("StreakBadge not found in lowered views")
            return
        }
        XCTAssertFalse(v.referencesUnresolvedSymbol,
                       "StreakBadge with cross-file BadgeSize.iconSize must not have unresolved symbols, got: \(v.unresolvedSymbols)")
        let numTokens = v.hostTokens.filter { $0.kind == .number }
        XCTAssertEqual(numTokens.count, 1,
                       "size.iconSize must produce exactly one numeric host token")
        XCTAssertTrue(numTokens.first?.source.contains("size.iconSize") == true,
                      "token source must contain size.iconSize, got: \(String(describing: numTokens.first?.source))")
    }

    /// DEMOTE-SAFE: a view reading a cross-file type's PRIVATE computed member must NOT
    /// lower (private members are excluded from the catalog — the cross-file thunk can't
    /// reach them). The view must demote (stay native) rather than emit a non-compiling thunk.
    func testCrossFilePrivateComputedMemberDoesNotLower() {
        let viewFile = """
        import SwiftUI
        struct StreakBadge: View {
            let count: Int
            let size: BadgeSize
            var body: some View {
                HStack(spacing: 6) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: size.iconSize))
                    Text("\\(count)")
                }
            }
        }
        """
        // File B: the computed member is PRIVATE — must NOT be in the cross-file catalog.
        let sharedFile = """
        enum BadgeSize {
            case small, large
            private var iconSize: CGFloat {
                switch self { case .small: return 16; case .large: return 32 }
            }
        }
        """
        let bundle = BodyLowering.crossFileBundle(sources: [viewFile, sharedFile])
        // The private member must NOT appear in the cross-file catalog.
        XCTAssertNil(bundle.computedMembers["BadgeSize"]?["iconSize"],
                     "a private computed member must be excluded from the cross-file catalog (cross-file thunk can't reach it)")
        let views = BodyLowering().lowerAllViews(source: viewFile, crossFile: bundle)
        guard let v = views.first(where: { $0.viewName == "StreakBadge" }) else {
            XCTFail("StreakBadge not found in lowered views")
            return
        }
        // The view references `size.iconSize` which can't be resolved → unresolved symbol.
        XCTAssertTrue(v.referencesUnresolvedSymbol,
                      "StreakBadge with a private cross-file member must have unresolved symbols (demote-safe)")
    }

    // MARK: - Two-pass inertness + coverage + demote-safety

    /// INERTNESS: a CONTROL view that already lowers in pass 1 (it has a cross-file struct
    /// used ONLY for its String fields, which resolve via the string-token host-projection
    /// channel) must produce a BYTE-IDENTICAL LoweredView (same guestBody, same inputs, same
    /// opaqueLeaves) whether or not the cross-file struct/enum marshalling catalogs are
    /// available in the bundle. This pins the two-pass guarantee: pass 1 result is NEVER
    /// replaced by a pass-2 result for a view that did not demote in pass 1.
    ///
    /// Setup: `PlantLabel` reads `plant.name` (String). The string-token host-projection
    /// channel resolves `plant.name` in pass 1 without needing to marshal the whole struct.
    /// The view lowers in pass 1 (`referencesUnmarshalledInput == false`). Even though the
    /// cross-file struct catalog would let pass 2 reconstruct `plant` as a `.flatStruct`
    /// (changing how `plant.name` is emitted), pass 2 must NOT run for this view.
    func testTwoPassInertness_ControlViewIsUnchangedByStructCatalogs() {
        let viewFile = """
        import SwiftUI
        struct PlantLabel: View {
            let plant: Plant
            var body: some View {
                Text(plant.name)
            }
        }
        """
        let modelFile = """
        struct Plant {
            let name: String
            let daysUntilWater: Int
        }
        """
        // Full bundle WITH cross-file struct catalogs populated.
        let bundleWith = BodyLowering.crossFileBundle(sources: [viewFile, modelFile])
        XCTAssertNotNil(bundleWith.structs["Plant"], "Plant must be in bundle.structs")
        // Baseline bundle WITHOUT struct/enum catalogs — simulates the 1.6.35 behavior.
        let bundleWithout = BodyLowering.CrossFileBundle(
            stringFields: bundleWith.stringFields,
            scalarFields: bundleWith.scalarFields,
            collectionFields: bundleWith.collectionFields,
            reactiveShapes: bundleWith.reactiveShapes,
            computedMembers: bundleWith.computedMembers,
            structs: [:], enums: [:],
            observableClassNames: bundleWith.observableClassNames)
        let viewsWith = BodyLowering().lowerAllViews(source: viewFile, crossFile: bundleWith)
        let viewsWithout = BodyLowering().lowerAllViews(source: viewFile, crossFile: bundleWithout)
        guard let vWith = viewsWith.first(where: { $0.viewName == "PlantLabel" }),
              let vWithout = viewsWithout.first(where: { $0.viewName == "PlantLabel" }) else {
            XCTFail("PlantLabel not found in lowered views"); return
        }
        // The view must already lower in pass 1 (string-token host-projection suffices).
        XCTAssertFalse(vWithout.referencesUnmarshalledInput,
                       "PlantLabel must not demote in pass 1 (string-token projection resolves plant.name)")
        XCTAssertFalse(vWith.referencesUnmarshalledInput,
                       "PlantLabel must not demote with struct catalogs either")
        // INERTNESS: the two-pass design must produce byte-identical output when pass 1 lowers.
        // If pass 2 were to run (incorrectly), it would change guestBody from
        // `N.text(__strtok_...)` (string-token) → `N.text("plant.name")` (flatStruct field).
        XCTAssertEqual(vWith.guestBody, vWithout.guestBody,
                       "guestBody must be byte-identical WITH vs WITHOUT struct catalogs (inertness: pass 2 must not run for a non-demoting view)")
        let withInputNames = vWith.inputs.map { "\($0.name):\($0.kind)" }.sorted()
        let withoutInputNames = vWithout.inputs.map { "\($0.name):\($0.kind)" }.sorted()
        XCTAssertEqual(withInputNames, withoutInputNames,
                       "inputs must be identical WITH vs WITHOUT struct catalogs (inertness)")
        XCTAssertEqual(vWith.opaqueLeaves.map(\.id).sorted(), vWithout.opaqueLeaves.map(\.id).sorted(),
                       "opaqueLeaves ids must be identical WITH vs WITHOUT struct catalogs (inertness)")
    }

    /// COVERAGE: a TARGET view (`let plant: Plant`, cross-file struct used in a plain boolean
    /// `if` condition) must flip from demoted → lowered when the cross-file struct catalog is
    /// present in the bundle (pass 2 kicks in).
    ///
    /// Mechanism: `if plant.isReady { … }` with `plant: Plant` (`.unsupported` in pass 1 since
    /// `Plant` is not in the per-file catalog). The emitter emits the boolean condition verbatim
    /// (`plant.isReady`) into the guestBody, so `guestBodyReferencesAny(guestBody, ["plant"])`
    /// is TRUE → `referencesUnmarshalledInput = true` → pass 2 runs → `plant` becomes
    /// `.flatStruct` → the condition compiles correctly → `referencesUnmarshalledInput = false`.
    func testTwoPassCoverage_DemotingViewLowersViaPassTwo() {
        // File A: ReadyBadge uses `plant.isReady` in a plain boolean condition.
        let viewFile = """
        import SwiftUI
        struct ReadyBadge: View {
            let plant: Plant
            var body: some View {
                if plant.isReady {
                    Text("Ready")
                } else {
                    Text("Waiting")
                }
            }
        }
        """
        // File B: Plant is a flat struct with a Bool field (isReady).
        let modelFile = """
        struct Plant {
            let name: String
            let isReady: Bool
        }
        """
        // WITHOUT the struct catalog: plant is `.unsupported`, `plant.isReady` is emitted
        // verbatim in the guestBody → referencesUnmarshalledInput must be TRUE.
        let bundleWithout = BodyLowering.CrossFileBundle(
            stringFields: BodyLowering.crossFileBundle(sources: [viewFile, modelFile]).stringFields,
            scalarFields: [:], collectionFields: [:], reactiveShapes: [:],
            computedMembers: [:], structs: [:], enums: [:],
            observableClassNames: [])
        let viewsWithout = BodyLowering().lowerAllViews(source: viewFile, crossFile: bundleWithout)
        guard let vWithout = viewsWithout.first(where: { $0.viewName == "ReadyBadge" }) else {
            XCTFail("ReadyBadge not found in lowered views (pass 1)"); return
        }
        XCTAssertTrue(vWithout.referencesUnmarshalledInput || vWithout.referencesUnresolvedSymbol,
                      "ReadyBadge must demote in pass 1 (plant.isReady appears verbatim in guestBody but plant is .unsupported)")
        // WITH the full bundle (struct catalog populated): pass 2 should lift the view.
        let bundleWith = BodyLowering.crossFileBundle(sources: [viewFile, modelFile])
        XCTAssertNotNil(bundleWith.structs["Plant"], "Plant must be in bundle.structs for pass 2")
        let viewsWith = BodyLowering().lowerAllViews(source: viewFile, crossFile: bundleWith)
        guard let vWith = viewsWith.first(where: { $0.viewName == "ReadyBadge" }) else {
            XCTFail("ReadyBadge not found in lowered views (pass 2)"); return
        }
        // COVERAGE: the view must NOW lower (pass 2 resolved the cross-file struct).
        XCTAssertFalse(vWith.referencesUnmarshalledInput,
                       "ReadyBadge must lower WITH cross-file struct catalog (pass 2 coverage)")
        XCTAssertFalse(vWith.referencesUnresolvedSymbol,
                       "ReadyBadge guestBody must have no unresolved symbols after pass 2")
        // The `plant` input must be `.flatStruct` in the pass-2 result.
        let plantInput = vWith.inputs.first(where: { $0.name == "plant" })
        XCTAssertNotNil(plantInput, "plant input must be present")
        if case .flatStruct = plantInput?.kind { /* correct */ } else {
            XCTFail("plant input must be .flatStruct in pass-2 result, got \(String(describing: plantInput?.kind))")
        }
    }

    /// DEMOTE-SAFETY: a struct declared in 2+ files with the SAME name (ambiguous) must NOT be
    /// admitted into the cross-file struct catalog. Even in pass 2, the view must remain demoted
    /// because neither file's shape can be safely trusted.
    ///
    /// The body uses `widget.isActive` in a boolean condition — the same mechanism that makes
    /// pass 2 trigger — but since `Widget` is ambiguous (2 files), it's absent from `bundle.structs`,
    /// so pass 2 sees the same empty catalog for `Widget` and the view stays demoted.
    func testTwoPassDemoteSafety_AmbiguousStructDoesNotLower() {
        // Two files both define `Widget` — different field shapes (one has `isActive`, the other has `count`).
        let fileA = "struct Widget { let title: String; let isActive: Bool }"
        let fileB = "struct Widget { let title: String; let count: Int }"
        let viewFile = """
        import SwiftUI
        struct WidgetRow: View {
            let widget: Widget
            var body: some View {
                if widget.isActive {
                    Text("Active")
                } else {
                    Text("Inactive")
                }
            }
        }
        """
        let bundle = BodyLowering.crossFileBundle(sources: [viewFile, fileA, fileB])
        // Widget must be absent from the cross-file struct catalog (ambiguous — 2 files define it).
        XCTAssertNil(bundle.structs["Widget"],
                     "Widget declared in 2+ files must be dropped from bundle.structs (ambiguity safety)")
        // The view must remain demoted (pass 1 AND pass 2 both fail — Widget is not in the catalog).
        let views = BodyLowering().lowerAllViews(source: viewFile, crossFile: bundle)
        guard let v = views.first(where: { $0.viewName == "WidgetRow" }) else {
            XCTFail("WidgetRow not found in lowered views"); return
        }
        XCTAssertTrue(v.referencesUnmarshalledInput || v.referencesUnresolvedSymbol,
                      "WidgetRow must demote for an ambiguous cross-file struct (pass 2 still demotes — Widget not in catalog)")
    }

    /// NEAR-MISS demote: a view reading a cross-file type's computed `String?` member
    /// must NOT lower via the string-token path (optional strings are excluded — the
    /// thunk emits `.string(String?)` which doesn't compile).
    func testCrossFileOptionalComputedStringMemberDoesNotProject() {
        let viewFile = """
        import SwiftUI
        struct LabelView: View {
            let item: Item
            var body: some View {
                Text(item.subtitle)
            }
        }
        """
        // File B: subtitle is an optional String → excluded from the computed-member catalog.
        let sharedFile = """
        struct Item {
            var subtitle: String? { nil }
        }
        """
        let cat = BodyLowering.crossFileComputedMemberCatalog(sources: [sharedFile])
        XCTAssertNil(cat["Item"]?["subtitle"],
                     "optional computed String must be excluded from the cross-file computed-member catalog")
    }
}
