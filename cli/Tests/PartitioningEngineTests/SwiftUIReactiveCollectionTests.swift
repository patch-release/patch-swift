// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CodeGenerator
import SwiftParser
import SwiftSyntax

/// Reactive-collection marshalling (the lever that lets a `ForEach(vm.items)` over a reactive
/// view-model's collection lower to a bound guest loop instead of native-slotting the rows).
/// The reactive member is registered as a synthetic `.flatStruct` input carrying its marshallable
/// collection fields; the SDK marshals it as a nested object `{"vm":{"items":[…]}}`. Scalar/String
/// reads keep host-projecting (1.6.9). Build-safe = demote-safe.
final class SwiftUIReactiveCollectionTests: XCTestCase {

    func testForEachOverObservableObjectCollectionLowersToBoundLoop() throws {
        let source = """
        import SwiftUI
        import Combine
        struct Player { var name: String; var score: Int }
        final class GameVM: ObservableObject {
            @Published var players: [Player] = []
        }
        struct Leaderboard: View {
            @StateObject var vm = GameVM()
            var body: some View {
                VStack {
                    ForEach(vm.players, id: \\.name) { player in
                        HStack { Text(player.name); Text("\\(player.score)") }
                    }
                }
            }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source)
            .first { $0.viewName == "Leaderboard" })
        let g = lowered.guestBody
        XCTAssertTrue(g.contains("for player in vm.players"),
                      "ForEach over a reactive collection must bind the loop var: \(g)")
        XCTAssertTrue(g.contains("N.forEach("), "still a forEach node: \(g)")
        XCTAssertTrue(g.contains("player.name"), "row reads element.name: \(g)")
        XCTAssertFalse(lowered.referencesUnmarshalledInput,
                       "the reactive collection is marshalled — no demote: \(g)")
        // `vm` is registered as a flat-struct input whose `players` field is a struct-array.
        let vm = try XCTUnwrap(lowered.inputs.first { $0.name == "vm" })
        XCTAssertEqual(vm.kind, .flatStruct)
        let el = try XCTUnwrap(vm.structElement)
        XCTAssertEqual(el.typeName, "GameVM")
        XCTAssertTrue(el.fields.contains { $0.name == "players" }, "carries the collection field")
    }

    func testForEachOverObservableMacroStateObjectCollectionLowers() throws {
        // iOS-17 `@Observable` model HELD by `@StateObject` (a safe-to-marshal wrapper). The
        // `@Environment(T.self)` form is intentionally NOT marshalled (bug #8 — see the demote
        // test below); `@StateObject`/`@ObservedObject` hold their object so they're safe.
        let source = """
        import SwiftUI
        import Observation
        struct Item { var title: String }
        @Observable final class Store { var items: [Item] = [] }
        struct ItemsScreen: View {
            @StateObject private var store = Store()
            var body: some View {
                List {
                    ForEach(store.items, id: \\.title) { item in Text(item.title) }
                }
            }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source)
            .first { $0.viewName == "ItemsScreen" })
        let g = lowered.guestBody
        XCTAssertTrue(g.contains("for item in store.items"),
                      "ForEach over a held-reactive collection must bind the loop var: \(g)")
        XCTAssertTrue(g.contains("item.title"), "row reads element.title: \(g)")
        XCTAssertFalse(lowered.referencesUnmarshalledInput, "marshalled — no demote: \(g)")
    }

    func testReactiveScalarStillHostProjectsAlongsideCollection() throws {
        // The collection marshals AND a scalar read of the SAME reactive member still
        // host-projects (1.6.9 untouched) — they coexist. Held via `@StateObject` (safe wrapper).
        let source = """
        import SwiftUI
        import Observation
        struct Row { var label: String }
        @Observable final class VM { var rows: [Row] = []; var loading: Bool = false }
        struct Screen: View {
            @StateObject private var vm = VM()
            var body: some View {
                VStack {
                    if vm.loading { Text("Loading") }
                    ForEach(vm.rows, id: \\.label) { r in Text(r.label) }
                }
            }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source)
            .first { $0.viewName == "Screen" })
        let g = lowered.guestBody
        XCTAssertTrue(g.contains("for r in vm.rows"), "collection marshalled: \(g)")
        XCTAssertFalse(lowered.referencesUnmarshalledInput, "no demote: \(g)")
        // `vm.loading` host-projects to a numeric token (the scalar read still rides the thunk).
        XCTAssertTrue(lowered.hostTokens.contains { $0.kind == .number && $0.source.contains("vm.loading") }
                      || g.contains("__numtok_"),
                      "scalar read host-projects: tokens=\(lowered.hostTokens) body=\(g)")
    }

    func testReactiveStringReadHostProjectsNotEmittedVerbatim() throws {
        // BUG #7: a reactive String field read (`Text(vm.title)`) alongside a marshalled
        // collection must HOST-PROJECT (a string token, resolved by the thunk), NOT be emitted
        // verbatim against the synthetic guest struct (which carries ONLY the collection field —
        // `title` isn't there, so a verbatim `vm.title` would render wrong / fail to bind).
        let source = """
        import SwiftUI
        import Observation
        struct Row { var label: String }
        @Observable final class VM { var rows: [Row] = []; var title: String = "" }
        struct Screen: View {
            @StateObject private var vm = VM()
            var body: some View {
                VStack {
                    Text(vm.title)
                    ForEach(vm.rows, id: \\.label) { r in Text(r.label) }
                }
            }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source)
            .first { $0.viewName == "Screen" })
        let g = lowered.guestBody
        XCTAssertTrue(g.contains("for r in vm.rows"), "collection still marshals: \(g)")
        // The String read host-projects to a string token (resolved natively by the thunk) —
        // it must NOT leak `vm.title` verbatim into the guest tree against the synthetic struct.
        XCTAssertTrue(lowered.hostTokens.contains { $0.kind == .string && $0.source.contains("vm.title") },
                      "reactive String read must host-project, not emit verbatim: tokens=\(lowered.hostTokens) body=\(g)")
        XCTAssertFalse(lowered.referencesUnmarshalledInput, "no demote: \(g)")
    }

    func testEnvironmentObjectReactiveCollectionDemotesSafely() throws {
        // BUG #8 SAFE-SURFACE: an `@Environment(T.self)`-injected reactive collection is NOT
        // marshalled — the SDK can't eagerly unwrap an absent environment object without an
        // uncatchable trap. So the ForEach must NOT lower to a bound loop; it native-demotes.
        let source = """
        import SwiftUI
        import Observation
        struct Item { var title: String }
        @Observable final class Store { var items: [Item] = [] }
        struct ItemsScreen: View {
            @Environment(Store.self) private var store
            var body: some View {
                List {
                    ForEach(store.items, id: \\.title) { item in Text(item.title) }
                }
            }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source)
            .first { $0.viewName == "ItemsScreen" })
        // `store` must NOT be registered as a marshalled flat-struct input (env-injected = unsafe).
        let store = lowered.inputs.first { $0.name == "store" }
        XCTAssertNotEqual(store?.kind, .flatStruct,
                          "an @Environment-injected reactive collection must not be marshalled")
        XCTAssertFalse(lowered.guestBody.contains("for item in store.items"),
                       "the env-injected ForEach must not lower to a bound loop: \(lowered.guestBody)")
    }

    func testEnvironmentObjectClassicReactiveCollectionDemotesSafely() throws {
        // Same safe-surface gate for the classic `@EnvironmentObject` wrapper.
        let source = """
        import SwiftUI
        import Combine
        struct Item { var title: String }
        final class Store: ObservableObject { @Published var items: [Item] = [] }
        struct ItemsScreen: View {
            @EnvironmentObject var store: Store
            var body: some View {
                List {
                    ForEach(store.items, id: \\.title) { item in Text(item.title) }
                }
            }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source)
            .first { $0.viewName == "ItemsScreen" })
        let store = lowered.inputs.first { $0.name == "store" }
        XCTAssertNotEqual(store?.kind, .flatStruct,
                          "an @EnvironmentObject reactive collection must not be marshalled")
        XCTAssertFalse(lowered.guestBody.contains("for item in store.items"),
                       "the @EnvironmentObject ForEach must not lower to a bound loop: \(lowered.guestBody)")
    }

    func testCrossFileReactiveCollectionLowersViaBundleButNotPerFile() throws {
        // The real-app shape: the view in one file, the @Observable model + element struct in
        // ANOTHER (a real app's SoundsScreen ← SoundDatabase/Sound in Services/).
        // With the cross-file bundle the ForEach lowers; per-file it does NOT — proving
        // the gap this closes (the build/fingerprint feed the bundle; bare lowerAllViews does not).
        let modelSource = """
        import Observation
        struct Sound { var label: String; var ipa: String }
        @Observable final class SoundDatabase { var sounds: [Sound] = [] }
        """
        // HELD via `@StateObject` (a safe-to-marshal wrapper). The env-injected form demotes
        // (bug #8); this test isolates the CROSS-FILE type-resolution unlock, not the wrapper kind.
        let viewSource = """
        import SwiftUI
        import Observation
        struct SoundsScreen: View {
            @StateObject private var database = SoundDatabase()
            var body: some View {
                List {
                    ForEach(database.sounds, id: \\.label) { sound in Text(sound.label) }
                }
            }
        }
        """
        let bundle = BodyLowering.crossFileBundle(sources: [modelSource, viewSource])
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: viewSource, crossFile: bundle)
            .first { $0.viewName == "SoundsScreen" })
        XCTAssertTrue(lowered.guestBody.contains("for sound in database.sounds"),
                      "cross-file reactive ForEach lowers via the bundle: \(lowered.guestBody)")
        XCTAssertFalse(lowered.referencesUnmarshalledInput, "no demote: \(lowered.guestBody)")
        // Per-file (no cross-file bundle) does NOT lower it — the model is in another file.
        let perFile = try XCTUnwrap(BodyLowering().lowerAllViews(source: viewSource)
            .first { $0.viewName == "SoundsScreen" })
        XCTAssertFalse(perFile.guestBody.contains("for sound in database.sounds"),
                       "per-file does NOT lower a cross-file reactive ForEach (the gap cross-file closes)")
    }

    func testReactiveCollectionOfNonMarshallableElementDemotesSafely() throws {
        // The element type isn't a flat/marshallable struct (it has a closure field) → the
        // reactive collection is NOT registered; the ForEach stays a native slot (no bound loop,
        // no guest leak). Build-safe = demote-safe.
        let source = """
        import SwiftUI
        import Observation
        struct Handler { var run: () -> Void }
        @Observable final class VM { var handlers: [Handler] = [] }
        struct Screen: View {
            @Environment(VM.self) private var vm
            var body: some View {
                ForEach(0..<vm.handlers.count, id: \\.self) { _ in Text("x") }
            }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source)
            .first { $0.viewName == "Screen" })
        // `vm` must NOT be registered as a marshalled flat-struct input (Handler is non-marshallable).
        let vm = lowered.inputs.first { $0.name == "vm" }
        XCTAssertNotEqual(vm?.kind, .flatStruct,
                          "a reactive collection of a non-marshallable element must not be marshalled")
    }
}
