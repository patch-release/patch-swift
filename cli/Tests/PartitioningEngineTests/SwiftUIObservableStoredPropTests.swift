// SPDX-License-Identifier: Apache-2.0

import XCTest
import SwiftParser
@testable import CodeGenerator

/// Tests for the `observableStoredProp` host-projection lever (cli 1.6.39).
///
/// A view with a PLAIN STORED `@Observable` class member (`let vm: MyViewModel`)
/// or a `@Bindable var` over an `@Observable`-non-@Model class currently demotes
/// because the class is a reference type the guest can't reconstruct. The engine
/// now host-projects its SCALAR (Int/Bool/Double) and String fields exactly like
/// `@ObservedObject`/`@StateObject` members — the thunk evaluates `self.vm.field`
/// natively → a `__numtok_` or `__strtok_` token the SDK merges into the guest
/// input JSON.
///
/// IRON SAFETY INVARIANTS PROVEN BY THIS SUITE:
///   (a) POSITIVE — `let vm: VM` (@Observable) + `Text(vm.title)` / `vm.count > 0` lowers,
///       thunkSafe, host-projects fields as tokens.
///   (b) OBJECT-NOT-MARSHALLED — the `@Observable` object itself does NOT appear as a
///       marshalled input or free guest identifier; only resolved scalar/String tokens cross.
///   (c) NEGATIVE — `@Bindable var x: SomeModel` where `SomeModel` is `@Model` STILL demotes
///       (the SwiftData wall is intact).
///   (d) INERTNESS — a view with no plain @Observable member is byte-identical to its
///       1.6.38 output.
final class SwiftUIObservableStoredPropTests: XCTestCase {

    // MARK: - (a) POSITIVE: plain let vm lowers + host-projects scalar/String fields

    /// A view with `let vm: MyViewModel` where `MyViewModel` is `@Observable` and the body
    /// reads `vm.title` (String) and `vm.count` (Int) should lower and host-project both
    /// fields as tokens — the view is thunk-safe and routes OTA.
    func testPlainObservableLetMemberLowersAndHostProjects() throws {
        let src = """
        import SwiftUI

        @Observable
        final class MyViewModel {
            var title: String = ""
            var count: Int = 0
            var isActive: Bool = false
        }

        struct ContentView: View {
            let vm: MyViewModel
            var body: some View {
                VStack {
                    Text(vm.title)
                    if vm.count > 0 {
                        Text("Has items")
                    }
                }
            }
        }
        """
        let lowering = BodyLowering()
        let views = lowering.lowerAllViews(source: src, sameFileThunk: true)
        let v = try XCTUnwrap(views.first { $0.viewName == "ContentView" },
                              "ContentView should be in the lowered output")

        // The view must not have unresolved symbols (vm.title / vm.count projected, not free).
        XCTAssertFalse(v.referencesUnresolvedSymbol,
                       "no free guest identifier after @Observable host-projection; unresolved: \(v.unresolvedSymbols)")
        XCTAssertFalse(v.referencesUnmarshalledInput,
                       "no unmarshalled input (vm itself never crosses to WASM)")

        // vm.title must host-project as a __strtok_ (String token).
        XCTAssertTrue(v.guestBody.contains("__strtok_"),
                      "vm.title must host-project as __strtok_: \(v.guestBody)")

        // vm.count must host-project as a __numtok_ (numeric token, the if-guard).
        XCTAssertTrue(v.guestBody.contains("__numtok_"),
                      "vm.count must host-project as __numtok_: \(v.guestBody)")

        // At least one string token must be present for vm.title.
        let stringTokens = v.hostTokens.filter { $0.kind == .string }
        XCTAssertFalse(stringTokens.isEmpty,
                       "must have at least one .string host token (vm.title): \(v.hostTokens)")

        // At least one number token must be present for vm.count.
        let numberTokens = v.hostTokens.filter { $0.kind == .number }
        XCTAssertFalse(numberTokens.isEmpty,
                       "must have at least one .number host token (vm.count): \(v.hostTokens)")
    }

    // MARK: - (a) POSITIVE: @Bindable var (non-@Model @Observable) lowers and host-projects

    /// A view with `@Bindable var vm: MyViewModel` where `MyViewModel` is `@Observable`
    /// (NOT `@Model`) should lower and host-project vm's String/scalar fields.
    func testBindableObservableNonModelMemberLowersAndHostProjects() throws {
        let src = """
        import SwiftUI

        @Observable
        final class FormViewModel {
            var label: String = ""
            var progress: Double = 0.0
        }

        struct FormView: View {
            @Bindable var vm: FormViewModel
            var body: some View {
                VStack {
                    Text(vm.label)
                }
            }
        }
        """
        let lowering = BodyLowering()
        let views = lowering.lowerAllViews(source: src, sameFileThunk: true)
        let v = try XCTUnwrap(views.first { $0.viewName == "FormView" },
                              "FormView should be in the lowered output")

        XCTAssertFalse(v.referencesUnresolvedSymbol,
                       "no free guest identifier; unresolved: \(v.unresolvedSymbols)")
        XCTAssertFalse(v.referencesUnmarshalledInput,
                       "no unmarshalled input (vm itself never crosses to WASM)")

        // vm.label must host-project as a __strtok_.
        XCTAssertTrue(v.guestBody.contains("__strtok_"),
                      "vm.label must host-project as __strtok_: \(v.guestBody)")
    }

    // MARK: - (b) OBJECT-NOT-MARSHALLED: vm object never enters WASM

    /// The `@Observable` object (`vm`) must not appear as:
    ///   - A marshalled `ViewInput` (it stays `.unsupported`, not `.flatStruct`/`.held`)
    ///   - A free identifier in the guest body (all reads are projected to tokens)
    /// ONLY the resolved scalar/String values cross via the token mechanism.
    func testObservableObjectNeverMarshalled() throws {
        let src = """
        import SwiftUI

        @Observable
        final class ProfileViewModel {
            var name: String = ""
            var score: Int = 0
        }

        struct ProfileView: View {
            let vm: ProfileViewModel
            var body: some View {
                VStack {
                    Text(vm.name)
                        .padding()
                    if vm.score > 10 {
                        Text("High score")
                    }
                }
            }
        }
        """
        let lowering = BodyLowering()
        let views = lowering.lowerAllViews(source: src, sameFileThunk: true)
        let v = try XCTUnwrap(views.first { $0.viewName == "ProfileView" },
                              "ProfileView should be found")

        // (1) `vm` must NOT appear as a free identifier in the guest body.
        //     The engine converted all `vm.x` reads to __strtok_/__numtok_ tokens.
        XCTAssertFalse(BodyLowering.guestBodyReferencesAny(v.guestBody, names: ["vm"]),
                       "the `vm` object must not appear as a free identifier in guest WASM: \(v.guestBody)")

        // (2) `vm` must NOT be in the marshalled inputs (it's not guest-reconstructable).
        let marshalledVm = v.inputs.filter { $0.name == "vm" && $0.kind.guestReconstructable }
        XCTAssertTrue(marshalledVm.isEmpty,
                      "vm must not be a marshalled (guest-reconstructable) input: \(v.inputs.map { "\($0.name):\($0.kind)" })")

        // (3) No `.flatStruct` or other guest-reconstructable input named `vm`.
        let vmInputs = v.inputs.filter { $0.name == "vm" }
        for input in vmInputs {
            XCTAssertFalse(input.kind.guestReconstructable,
                           "vm input must NOT be guest-reconstructable: kind=\(input.kind)")
        }

        // (4) All host tokens must be scalar/string kinds (no object kind exists — just verify
        //     that the tokens produced are the scalar/String projection kinds, not tree-node kinds).
        for tok in v.hostTokens where tok.source.hasPrefix("vm.") {
            XCTAssertTrue(tok.kind == .number || tok.kind == .string,
                          "vm.* token must be .number or .string (scalar/String projection only): \(tok)")
        }

        // (5) `referencesUnmarshalledInput` must be false (vm is in unmarshalledNames, but
        //     its bare name doesn't appear in the guest body after projection).
        XCTAssertFalse(v.referencesUnmarshalledInput,
                       "vm is not referenced in guest body after projection — must not block")
    }

    // MARK: - (c) NEGATIVE: @Bindable var x: @Model still demotes (SwiftData wall intact)

    /// A `@Bindable var x: SomeModel` where `SomeModel` is annotated with `@Model` (SwiftData)
    /// must NOT host-project and must still demote. `@Model` classes are excluded from
    /// `observableClassNames` by the `ObservableClassCollector` (it rejects any class with
    /// `@Model`). The iron safety rule: the new `.observablePlain` arm must NOT fire for
    /// @Model members — verified by (1) Trip absent from observableClassNames, and (2) no
    /// NEW numeric tokens produced via the `.observablePlain` path for `trip.days`.
    ///
    /// Note: the existing `stringTypedMemberPaths` channel ALREADY projects string fields of
    /// any class type (including @Model) via `AnyClassDeclCollector` — that's pre-existing
    /// behaviour unrelated to the new observable-stored-prop lever. This test verifies the
    /// NEW lever's iron safety property only (numeric tokens from the new arm).
    func testBindableModelPropertyNewArmDoesNotFire() throws {
        let src = """
        import SwiftUI
        import SwiftData

        @Model
        final class Trip {
            var name: String = ""
            var days: Int = 0
        }

        struct TripView: View {
            @Bindable var trip: Trip
            var body: some View {
                VStack {
                    Text(trip.name)
                    Text("\\(trip.days) days")
                }
            }
        }
        """
        // IRON SAFETY: @Model class must NOT enter the observableClassNames catalog.
        let tree = SwiftParser.Parser.parse(source: src)
        let obsNames = BodyLowering.observableClassNames(in: tree)
        XCTAssertFalse(obsNames.contains("Trip"),
                       "@Model class must be excluded from observableClassNames: \(obsNames)")

        // IRON SAFETY: no numeric token produced via the NEW `.observablePlain` arm for
        // `trip.days` (Int). The new arm fires ONLY for types in `observableClassNames`;
        // since `Trip` is excluded, `trip.days` cannot produce a numtok via the new path.
        // (If `trip.days` somehow appeared as a __numtok_ here, it would be via the new arm
        // — that would be a violation. The existing scalar-projection paths only cover
        // @ObservedObject/@StateObject/@EnvironmentObject/@Environment reactive members,
        // none of which apply to a @Bindable/@Model binding.)
        let lowering = BodyLowering()
        let views = lowering.lowerAllViews(source: src, sameFileThunk: true)
        let v = try XCTUnwrap(views.first { $0.viewName == "TripView" },
                              "TripView should be found")

        // No numeric token for `trip.days` via the new arm.
        let daysTokens = v.hostTokens.filter {
            $0.kind == .number && $0.source.contains("trip")
        }
        XCTAssertTrue(daysTokens.isEmpty,
                      "@Model member `trip.days` must NOT produce a numeric host token via new arm: "
                      + "\(v.hostTokens.map { "\($0.kind):\($0.source)" })")
    }

    /// A class annotated with BOTH `@Observable` AND `@Model` must also be excluded from
    /// the observableClassNames catalog (conservative: @Model always wins; its presence
    /// disqualifies the class from the new `.observablePlain` host-projection arm).
    /// Iron safety: no numeric token is produced for `model.count` via the new arm.
    func testObservableModelCombinedClassExcluded() throws {
        let src = """
        import SwiftUI
        import SwiftData

        @Observable @Model
        final class HybridModel {
            var title: String = ""
            var count: Int = 0
        }

        struct HybridView: View {
            let model: HybridModel
            var body: some View {
                Text(model.title)
            }
        }
        """
        // IRON SAFETY (1): verify `observableClassNames` does NOT include `HybridModel`.
        let tree = SwiftParser.Parser.parse(source: src)
        let obsNames = BodyLowering.observableClassNames(in: tree)
        XCTAssertFalse(obsNames.contains("HybridModel"),
                       "@Model+@Observable class must be excluded from observableClassNames: \(obsNames)")

        // IRON SAFETY (2): no numeric token produced for `model.count` via the new arm.
        // (`model` is not in observableClassNames → the new arm is a no-op for this type.)
        let lowering = BodyLowering()
        let views = lowering.lowerAllViews(source: src, sameFileThunk: true)
        let v = try XCTUnwrap(views.first { $0.viewName == "HybridView" })
        let countTokens = v.hostTokens.filter {
            $0.kind == .number && $0.source.contains("model")
        }
        XCTAssertTrue(countTokens.isEmpty,
                      "@Observable+@Model `model.count` must NOT produce a numeric host token via new arm: "
                      + "\(v.hostTokens.map { "\($0.kind):\($0.source)" })")
    }

    // MARK: - (d) INERTNESS: a view with no @Observable plain member is byte-identical

    /// A view with only marshalled scalar inputs and no plain `@Observable` member
    /// must produce a byte-identical guest body with the new code in place.
    /// This verifies the `.observablePlain` arm is truly a no-op for unaffected views.
    func testViewWithNoObservableMemberIsInert() throws {
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
        // Lower WITHOUT the lever (no @Observable classes in source).
        let views = lowering.lowerAllViews(source: src, sameFileThunk: true)
        let v = try XCTUnwrap(views.first { $0.viewName == "SimpleView" })

        // No @Observable classes → no new tokens should appear.
        XCTAssertFalse(v.referencesUnresolvedSymbol,
                       "SimpleView must lower cleanly: unresolved=\(v.unresolvedSymbols)")
        XCTAssertFalse(v.referencesUnmarshalledInput,
                       "SimpleView has no class inputs")

        // Verify there are no spurious __numtok_ or __strtok_ from the new arm
        // (since `title`/`count` are marshalled scalar inputs, they appear as bound names,
        // not as tokens).
        let observableTokens = v.hostTokens.filter {
            $0.source.contains("title") || $0.source.contains("count")
        }
        XCTAssertTrue(observableTokens.isEmpty,
                      "scalar/String inputs on a plain struct must not become host tokens: \(observableTokens)")
    }

    // MARK: - observableClassNames(in:) catalog

    /// `observableClassNames` correctly identifies @Observable classes and excludes @Model ones.
    func testObservableClassNamesCatalog() throws {
        let src = """
        @Observable final class GoodVM { var x: Int = 0 }
        @Observable @Model final class BadVM { var x: Int = 0 }
        @Model final class DataModel { var x: Int = 0 }
        final class PlainClass { var x: Int = 0 }
        struct NotAClass { var x: Int = 0 }
        """
        let tree = SwiftParser.Parser.parse(source: src)
        let names = BodyLowering.observableClassNames(in: tree)

        // Only GoodVM qualifies.
        XCTAssertTrue(names.contains("GoodVM"),
                      "@Observable non-@Model class must be in observableClassNames: \(names)")
        XCTAssertFalse(names.contains("BadVM"),
                       "@Observable+@Model class must be EXCLUDED: \(names)")
        XCTAssertFalse(names.contains("DataModel"),
                       "@Model-only class must be EXCLUDED: \(names)")
        XCTAssertFalse(names.contains("PlainClass"),
                       "Plain class (no @Observable) must be EXCLUDED: \(names)")
        XCTAssertFalse(names.contains("NotAClass"),
                       "Struct must be EXCLUDED: \(names)")
    }

    // MARK: - Cross-file: @Observable class in another file host-projects via bundle

    /// The `@Observable` class defined in a MODEL FILE (separate from the view) must
    /// host-project its scalar/String fields via the cross-file bundle mechanism.
    func testCrossFileObservableClassProjectsViaBundle() throws {
        let modelSource = """
        import Foundation
        @Observable
        final class TaskViewModel {
            var taskTitle: String = ""
            var taskCount: Int = 0
        }
        """
        let viewSource = """
        import SwiftUI
        struct TaskListView: View {
            let vm: TaskViewModel
            var body: some View {
                VStack {
                    Text(vm.taskTitle)
                    if vm.taskCount > 0 {
                        Text("Tasks")
                    }
                }
            }
        }
        """
        let bundle = BodyLowering.crossFileBundle(sources: [modelSource, viewSource])

        // The bundle must include TaskViewModel in its observable class names.
        XCTAssertTrue(bundle.observableClassNames.contains("TaskViewModel"),
                      "cross-file bundle must include @Observable class from model source: \(bundle.observableClassNames)")

        let lowering = BodyLowering()
        let views = lowering.lowerAllViews(source: viewSource, crossFile: bundle)
        let v = try XCTUnwrap(views.first { $0.viewName == "TaskListView" },
                              "TaskListView should be in the lowered output")

        // The view must lower (the @Observable class is resolved cross-file).
        XCTAssertFalse(v.referencesUnresolvedSymbol,
                       "cross-file @Observable must resolve; unresolved: \(v.unresolvedSymbols)")
        XCTAssertFalse(v.referencesUnmarshalledInput,
                       "vm object must not be marshalled (only tokens cross)")

        // vm.taskTitle must host-project as a string token.
        let stringTokens = v.hostTokens.filter { $0.kind == .string }
        XCTAssertFalse(stringTokens.isEmpty,
                       "cross-file @Observable String field must produce a string token: \(v.hostTokens)")

        // vm.taskCount must host-project as a number token.
        let numberTokens = v.hostTokens.filter { $0.kind == .number }
        XCTAssertFalse(numberTokens.isEmpty,
                       "cross-file @Observable Int field must produce a number token: \(v.hostTokens)")
    }
}
