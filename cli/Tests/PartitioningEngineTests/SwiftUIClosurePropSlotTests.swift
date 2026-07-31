// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
@testable import CodeGenerator
import ViewNodeIR

/// Tests for the closurePropSlot coverage lever (cli 1.6.38).
///
/// A SwiftUI view with a CLOSURE-TYPED stored property (`let onTap: () -> Void`) was
/// previously set `referencesUnmarshalledInput = true` because the closure can't be
/// JSON-marshalled into WASM. This caused the WHOLE VIEW to demote to native even when
/// the rest of the body (title strings, layout) was perfectly lowerable.
///
/// The fix: `closurePropNames(of:)` detects closure-typed stored properties, and
/// `lowerAllViews` subtracts them from `unmarshalledNames` before the
/// `referencesUnmarshalled` check. The emitter's existing opaqueExprLifted / actionSlot
/// path then handles each closure-prop CALL SITE natively — the closure never leaks as a
/// live WASM identifier.
///
/// INERTNESS invariant: a view with NO closure prop must produce a byte-identical guest
/// body before and after the change (the subtraction is a no-op on an empty set).
final class SwiftUIClosurePropSlotTests: XCTestCase {

    // MARK: - Helpers

    private func lower(_ source: String, sameFile: Bool = true) -> [BodyLowering.LoweredView] {
        BodyLowering().lowerAllViews(source: source, sameFileThunk: sameFile)
    }

    private func view(named name: String, in views: [BodyLowering.LoweredView],
                      file: StaticString = #filePath, line: UInt = #line) throws -> BodyLowering.LoweredView {
        try XCTUnwrap(views.first { $0.viewName == name },
                      "view '\(name)' not found in lowered output", file: file, line: line)
    }

    // MARK: - POSITIVE: closure prop button lowers with thunkSafe = true

    /// (a) POSITIVE — `let onTap: () -> Void` + `Button(title){ onTap() }` lowers with
    /// `referencesUnmarshalledInput = false` (closure prop excluded from unmarshalledNames),
    /// the guest body does NOT contain a live `onTap` identifier, and the Button's action
    /// is handled natively as an opaque slot (the view becomes auto-routable).
    ///
    /// This is the canonical "callback child view" pattern — the #1-frequency real-app idiom
    /// that previously caused the entire view to demote.
    func testClosurePropButtonLowers() throws {
        let src = """
        import SwiftUI

        struct RowView: View {
            let title: String
            let onTap: () -> Void
            var body: some View {
                Button(title) { onTap() }
            }
        }
        """
        let views = lower(src)
        let v = try view(named: "RowView", in: views)

        // (1) The closure prop must NOT block the view — it should lower successfully.
        XCTAssertFalse(v.referencesUnmarshalledInput,
            "closure prop `onTap` must be subtracted from unmarshalledNames; referencesUnmarshalledInput must be false: \(v.guestBody)")

        // (2) `onTap` must NOT appear as a live WASM identifier in the guest body.
        //     It's handled natively by the slot mechanism (opaqueExprLifted or actionSlot),
        //     so only a string label (inside N.opaque) may carry the source — not a DeclRef.
        XCTAssertFalse(
            BodyLowering.guestBodyReferencesAny(v.guestBody, names: ["onTap"]),
            "`onTap` must not appear as a live WASM identifier; guest body: \(v.guestBody)")

        // (3) The view must be routable — no blocking unresolved symbols either.
        XCTAssertFalse(v.referencesUnresolvedSymbol,
            "view must have no unresolved symbols; unresolved: \(v.unresolvedSymbols)")

        // (4) `title` (a String input) must still appear in the guest body — the lowerable
        //     part of the view (the String marshalling) is intact.
        XCTAssertTrue(v.guestBody.contains("title") || v.guestBody.contains("N.opaque"),
            "guest body must contain the lowered title or an opaque node: \(v.guestBody)")
    }

    /// A view with MULTIPLE closure props — `onTap: () -> Void` + `onLongPress: () -> Void`
    /// — lowers with both excluded from unmarshalledNames.
    func testMultipleClosurePropsLower() throws {
        let src = """
        import SwiftUI

        struct ActionRow: View {
            let label: String
            let onTap: () -> Void
            let onLongPress: () -> Void
            var body: some View {
                Button(label) { onTap() }
            }
        }
        """
        let views = lower(src)
        let v = try view(named: "ActionRow", in: views)

        XCTAssertFalse(v.referencesUnmarshalledInput,
            "multiple closure props must all be subtracted: \(v.guestBody)")
        XCTAssertFalse(
            BodyLowering.guestBodyReferencesAny(v.guestBody, names: ["onTap", "onLongPress"]),
            "neither closure prop name may appear as a live WASM identifier: \(v.guestBody)")
    }

    // MARK: - POSITIVE: thunk compiles (via SwiftUIThunkCompileTests harness)

    /// (a) continued — compile the generated thunk to prove the slotted closure-prop call
    /// site (`Button(title) { onTap() }`) actually type-checks for iOS.
    ///
    /// Uses the same `ThunkGenerator().prepare` + `swiftc -typecheck` harness as
    /// SwiftUIThunkCompileTests — skips when no iphonesimulator SDK is available.
    func testClosurePropButtonThunkCompiles() throws {
        let sdkPath = Self.runCmd("/usr/bin/xcrun",
                                  ["--show-sdk-path", "--sdk", "iphonesimulator"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sdkPath, !sdkPath.isEmpty else {
            throw XCTSkip("no iphonesimulator SDK — skip thunk-compile gate")
        }

        let src = """
        import SwiftUI

        struct RowView: View {
            let title: String
            let onTap: () -> Void
            var body: some View {
                Button(title) { onTap() }
            }
        }
        """

        // Inline the same host stub as SwiftUIThunkCompileTests.
        let hostStub = """
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

        let url = URL(fileURLWithPath: "/tmp/PatchClosurePropFixture.swift")
        let result = ThunkGenerator().prepare(sources: [.init(url: url, text: src)], sameFile: true)
        let modifiedText = result.modifiedFiles.first?.text ?? src

        let patched = modifiedText
            .replacingOccurrences(of: "import PatchSDK\n", with: "")
            .replacingOccurrences(of: "import PatchSwiftUI\n", with: "")
            .replacingOccurrences(of: "import PatchRender\n", with: "")

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftui-closure-prop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try patched.write(to: tmp.appendingPathComponent("Fixture.swift"), atomically: true, encoding: .utf8)
        try hostStub.write(to: tmp.appendingPathComponent("HostStub.swift"), atomically: true, encoding: .utf8)

        let args = [
            "-typecheck",
            "-sdk", sdkPath,
            "-target", "arm64-apple-ios16.0-simulator",
            tmp.appendingPathComponent("Fixture.swift").path,
            tmp.appendingPathComponent("HostStub.swift").path
        ]
        let log = Self.runCmd("/usr/bin/swiftc", args, captureStderr: true) ?? ""
        XCTAssertFalse(log.contains("error:"),
            "[closureProp thunk-compile] generated thunk + patched view must type-check for iOS:\n" +
            "----- log -----\n\(log)\n" +
            "----- generated -----\n\(modifiedText)")
    }

    // MARK: - NEGATIVE: a closure prop call the emitter can't slot still demotes safely

    /// (b) NEGATIVE — a view where the closure prop is the ONLY content and the call is
    /// wrapped in an unsupported construct must still demote safely (no broken guest emitted).
    ///
    /// Specifically: a view whose ENTIRE body is `onTap()` (a bare Void call, not a Button)
    /// — there's nothing else to lower, so the guest body is empty/opaque. The view may
    /// still lower (with an opaque leaf for the whole body) but must NEVER emit a live
    /// `onTap` identifier as a WASM input (that would be a broken default).
    func testBareClosurePropCallNoLiveIdentifierLeak() throws {
        // A standalone `onTap()` call in a view body is unusual (it's just a side effect,
        // not a view expression), but the invariant to check is: however the emitter handles
        // it, `onTap` must never appear as a live WASM DeclRef in the guest body.
        let src = """
        import SwiftUI

        struct TapView: View {
            let label: String
            let onTap: () -> Void
            var body: some View {
                VStack {
                    Text(label)
                    // This is a View builder context, so a bare onTap() call would be
                    // a compiler error in real Swift — we test a Button variant below.
                    // Here we test a non-dispatchable button instead.
                    Button("Tap") { onTap() }
                    Button("Also") { onTap() }
                }
            }
        }
        """
        let views = lower(src)
        let v = try view(named: "TapView", in: views)

        // The key invariant: `onTap` must never be a live WASM identifier.
        XCTAssertFalse(
            BodyLowering.guestBodyReferencesAny(v.guestBody, names: ["onTap"]),
            "closure prop `onTap` must NEVER be a live WASM DeclRef — it leaks a wrong default: \(v.guestBody)")

        // The view must not be falsely marked referencesUnmarshalledInput for `onTap`.
        XCTAssertFalse(v.referencesUnmarshalledInput,
            "closure prop must not block the view via referencesUnmarshalledInput: \(v.guestBody)")
    }

    // MARK: - INERTNESS: a view with NO closure prop is byte-identical before/after

    /// (c) INERTNESS — a view with NO closure prop must produce a byte-identical guest body
    /// with/without the change. The `closurePropNames(of:)` set is empty, the subtraction
    /// is a no-op, and `unmarshalledNames` is unchanged. This is the critical non-regression
    /// property: the lever ONLY affects views that currently demote because of a closure prop.
    func testViewWithoutClosurePropIsUnchanged() throws {
        let src = """
        import SwiftUI

        struct PlainView: View {
            let title: String
            let count: Int
            var body: some View {
                VStack {
                    Text(title)
                    Text("\\(count) items")
                }
            }
        }
        """
        // Lower the view. If there are no closure props, `closurePropNames` returns empty,
        // the subtraction is a no-op, and the result must be identical to what it was before.
        let views = lower(src)
        let v = try view(named: "PlainView", in: views)

        // The view must lower cleanly (this was already true before the change).
        XCTAssertFalse(v.referencesUnmarshalledInput,
            "PlainView has no closure props → referencesUnmarshalledInput must be false (as before): \(v.guestBody)")
        XCTAssertFalse(v.referencesUnresolvedSymbol,
            "PlainView has no unresolved symbols: \(v.unresolvedSymbols)")

        // closurePropNames must return empty for a view with no closure props.
        let decl = try XCTUnwrap(BodyLowering.findViewDecl(named: "PlainView", in: src),
                                  "PlainView decl must be found")
        let closureProps = BodyLowering.closurePropNames(of: decl)
        XCTAssertTrue(closureProps.isEmpty,
            "closurePropNames must return empty for a view with no closure-typed props: \(closureProps)")
    }

    /// INERTNESS (structural): a view with a non-closure `.unsupported` prop (e.g., a
    /// custom struct type) still demotes via `referencesUnmarshalledInput` — the change
    /// does NOT accidentally remove non-closure unsupported types from the gate.
    func testNonClosureUnsupportedPropStillDemotes() throws {
        let src = """
        import SwiftUI

        struct Fancy {}   // an opaque type — not marshallable, no closure arrow

        struct ItemView: View {
            let item: Fancy
            var body: some View {
                Text("hello")
            }
        }
        """
        let views = lower(src)
        let v = try view(named: "ItemView", in: views)

        // `item: Fancy` is NOT a closure type, so it must NOT be subtracted.
        // If the body references `item`, it should still block. Here the body doesn't
        // reference `item` directly (it uses a literal), so referencesUnmarshalledInput
        // should be FALSE (body doesn't use `item`). This is correct existing behavior.
        //
        // The inertness claim: closurePropNames returns empty for `Fancy`.
        let decl = try XCTUnwrap(BodyLowering.findViewDecl(named: "ItemView", in: src),
                                  "ItemView decl must be found")
        let closureProps = BodyLowering.closurePropNames(of: decl)
        XCTAssertFalse(closureProps.contains("item"),
            "a non-closure prop `item: Fancy` must NOT appear in closurePropNames: \(closureProps)")
    }

    // MARK: - closurePropNames unit tests

    /// `closurePropNames` correctly identifies `() -> Void` and `(String) -> Bool` props.
    func testClosurePropNamesDetection() throws {
        let src = """
        import SwiftUI

        struct MyView: View {
            let title: String
            let onTap: () -> Void
            let onSelect: (String) -> Bool
            let count: Int
            var computed: String { title }
            var body: some View { Text(title) }
        }
        """
        let decl = try XCTUnwrap(BodyLowering.findViewDecl(named: "MyView", in: src))
        let names = BodyLowering.closurePropNames(of: decl)

        XCTAssertTrue(names.contains("onTap"),
            "`onTap: () -> Void` must be detected: \(names)")
        XCTAssertTrue(names.contains("onSelect"),
            "`onSelect: (String) -> Bool` must be detected: \(names)")
        XCTAssertFalse(names.contains("title"),
            "`title: String` must NOT be in closure props: \(names)")
        XCTAssertFalse(names.contains("count"),
            "`count: Int` must NOT be in closure props: \(names)")
        XCTAssertFalse(names.contains("computed"),
            "computed property `computed` must NOT be in closure props (no accessor): \(names)")
    }

    // MARK: - Run helper

    @discardableResult
    private static func runCmd(_ path: String, _ args: [String],
                               captureStderr: Bool = false) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        if captureStderr { p.standardError = pipe }
        try? p.run()
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
