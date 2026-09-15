// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
@testable import CodeGenerator
import ViewNodeIR

/// HYBRID-mode prepared-output compile net (the exact shape `patchcli prepare` writes today):
/// the developer's files with `dynamic` inserted + any in-file PATCH-THUNKS block, PLUS the
/// separate `Patch/Generated/PatchThunks.generated.swift`. Everything is swiftc-type-checked
/// together against the iOS simulator SDK and the `SwiftUIThunkCompileTests.hostStub` SDK
/// surface. `SwiftUIThunkCompileTests` covers the legacy same-file mode; this covers the
/// placement customers actually get.
///
/// Skips (does NOT fail) when no iphonesimulator SDK is present.
final class PreparedOutputCompileTests: XCTestCase {

    struct Outcome {
        var compiled: Bool
        var log: String
        var files: [String: String]      // file name → prepared text
        var result: ThunkGenerator.Result
        var all: String { files.sorted { $0.key < $1.key }.map { "// ==== \($0.key)\n\($0.value)" }.joined(separator: "\n") }
    }

    static func sdkPath() -> String? {
        let p = SwiftUIThunkCompileTests.run("/usr/bin/xcrun", ["--show-sdk-path", "--sdk", "iphonesimulator"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (p?.isEmpty ?? true) ? nil : p
    }

    /// Run the real HYBRID prepare over `sources` (file name → text), write the prepared tree
    /// + host stub to a temp dir, and type-check it. `extraFlags` are appended to swiftc.
    static func prepareHybridAndCompile(_ sources: [String: String],
                                        extraFlags: [String] = []) throws -> Outcome? {
        guard let sdk = sdkPath() else { return nil }
        let base = URL(fileURLWithPath: "/tmp/PatchHybridFixture")
        let srcs = sources.sorted { $0.key < $1.key }.map {
            ThunkGenerator.SourceFile(url: base.appendingPathComponent($0.key), text: $0.value)
        }
        let result = ThunkGenerator().prepare(sources: srcs, hybrid: true)
        var files = sources
        for m in result.modifiedFiles { files[m.url.lastPathComponent] = m.text }
        if !result.generatedFileContents.isEmpty {
            files[ThunkGenerator.thunkFileName] = result.generatedFileContents
        }
        let strip: (String) -> String = {
            $0.replacingOccurrences(of: "import PatchSDK\n", with: "")
              .replacingOccurrences(of: "import PatchSwiftUI\n", with: "")
              .replacingOccurrences(of: "import PatchRender\n", with: "")
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("prepared-output-compile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        var paths: [String] = []
        for (name, text) in files {
            let u = tmp.appendingPathComponent(name)
            try strip(text).write(to: u, atomically: true, encoding: .utf8)
            paths.append(u.path)
        }
        let stub = tmp.appendingPathComponent("HostStub.swift")
        try SwiftUIThunkCompileTests.hostStub.write(to: stub, atomically: true, encoding: .utf8)
        paths.append(stub.path)
        let args = ["-typecheck", "-sdk", sdk, "-target", "arm64-apple-ios17.0-simulator"]
            + extraFlags + paths.sorted()
        let log = SwiftUIThunkCompileTests.run("/usr/bin/swiftc", args, captureStderr: true) ?? ""
        return Outcome(compiled: !log.contains("error:"), log: log, files: files, result: result)
    }

    // MARK: - Bug 1: GeometryReader proxy values leaking into host-side generated Swift

    /// The customer's OnboardingScreen shape: a GeometryReader whose child VStack carries a
    /// `.frame(height:)` computed from the proxy, with a child that can't lower (a custom view)
    /// so part of the reader's subtree becomes a NATIVE slot. The rewritten `__geo_height`
    /// (only valid inside the WASM guest) must NEVER reach the host-side thunk.
    static let onboardingGeometry = """
    import SwiftUI

    struct HeroArt: View {
        var body: some View { Circle().fill(Color.orange) }
    }

    extension View {
        func cardChrome() -> some View { self.background(Color.gray.opacity(0.1)) }
    }

    struct OnboardingScreen: View {
        let title: String
        @State private var page = 0
        var body: some View {
            GeometryReader { geometry in
                VStack(spacing: 16) {
                    HeroArt()
                    Text(title)
                        .font(.title)
                }
                .frame(height: max(220, min(geometry.size.height * 0.40, 420)))
                .cardChrome()
                Text("Welcome aboard")
                    .frame(width: geometry.size.width * 0.8)
            }
        }
    }
    """

    func testGeometryValueNeverLeaksIntoHostThunk() throws {
        guard let o = try Self.prepareHybridAndCompile(["OnboardingScreen.swift": Self.onboardingGeometry]) else {
            throw XCTSkip("no iphonesimulator SDK")
        }
        XCTAssertTrue(o.compiled, "prepared output must type-check:\n\(o.log)\n----\n\(o.all)")
        for (name, text) in o.files where name != "OnboardingScreen.swift" || text.contains("PATCH-THUNKS") {
            XCTAssertFalse(text.contains("__geo_"), "reserved guest identifier leaked into host Swift (\(name)):\n\(text)")
        }
    }

    /// The EditorTimeline shape: the proxy value is read inside a non-lowerable leaf (a custom
    /// view taking the width as an argument) and in an offset.
    static let editorTimelineGeometry = """
    import SwiftUI

    struct TimelineTrack: View {
        let width: CGFloat
        let progress: Double
        var body: some View { Rectangle().frame(width: width * progress) }
    }

    struct EditorTimeline: View {
        let progress: Double
        let label: String
        var body: some View {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    TimelineTrack(width: proxy.size.width, progress: progress)
                    Text(label)
                        .offset(x: proxy.size.width * progress)
                }
            }
            .frame(height: 44)
        }
    }
    """

    func testGeometryValueInCustomChildArgNeverLeaks() throws {
        guard let o = try Self.prepareHybridAndCompile(["EditorTimeline.swift": Self.editorTimelineGeometry]) else {
            throw XCTSkip("no iphonesimulator SDK")
        }
        XCTAssertTrue(o.compiled, "prepared output must type-check:\n\(o.log)\n----\n\(o.all)")
        for (name, text) in o.files {
            XCTAssertFalse(text.contains("__geo_"), "reserved guest identifier leaked into host Swift (\(name)):\n\(text)")
        }
    }

    /// A lifted display literal inside a slotted leaf WITHIN a GeometryReader: its recorded
    /// fingerprint byte range must point at the literal in the ORIGINAL file (the reader body is
    /// lowered from a detached, proxy-rewritten copy — ranges taken from that copy are garbage,
    /// and the fingerprint would normalize the wrong bytes).
    func testGeometryReaderLiftedLiteralRangesPointAtOriginalSource() throws {
        let src = """
        import SwiftUI
        struct Badge: View {
            let text: String
            var body: some View { Text(text) }
        }
        struct Header: View {
            let subtitle: String
            var body: some View {
                GeometryReader { proxy in
                    VStack {
                        Text(subtitle)
                            .frame(width: proxy.size.width / 2)
                        Badge(text: "New arrivals")
                    }
                }
            }
        }
        """
        let lowered = BodyLowering().lowerAllViews(source: src)
        guard let v = lowered.first(where: { $0.viewName == "Header" }) else { return XCTFail("no Header") }
        let bytes = Array(src.utf8)
        var checked = 0
        for leaf in v.opaqueLeaves {
            for (k, r) in leaf.stringArgRanges.enumerated() {
                XCTAssertTrue(r.lowerBound >= 0 && r.upperBound <= bytes.count, "range out of bounds: \(r)")
                guard r.lowerBound >= 0 && r.upperBound <= bytes.count else { continue }
                let text = String(decoding: bytes[r], as: UTF8.self)
                XCTAssertTrue(text.contains(leaf.stringArgs[k]),
                              "range \(r) must cover literal '\(leaf.stringArgs[k])' but covers '\(text)'")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 0, "expected a lifted literal inside the reader: \(v.opaqueLeaves)")
        // No coverage regression: a reader whose native leaves don't touch geometry still LOWERS.
        XCTAssertTrue(v.guestBody.contains("N.geometryReader"), "reader must still lower:\n\(v.guestBody)")
    }

    func testReservedGuestIdentifierScanIsBoundaryExact() {
        XCTAssertEqual(BodyLowering.reservedGuestIdentifiers(in: "min(__geo_height * 0.4, 420)"), ["__geo_height"])
        XCTAssertEqual(BodyLowering.reservedGuestIdentifiers(in: "Double(__numtok_nt_ab12) + _patchInputs.count"),
                       ["__numtok_nt_ab12", "_patchInputs"])
        // The HOST thunk's own helpers and ordinary developer names never match.
        XCTAssertEqual(BodyLowering.reservedGuestIdentifiers(in:
            "self.__patchSlots(); self.__patchDispatchCallback(\"x\"); my__geo_width; a_patchInputs"), [])
    }

    /// The prove-or-demote net itself: a thunk whose host-side slot source carries a guest-only
    /// identifier must fail per-view validation (the view is demoted, never written).
    func testThunkValidationDemotesReservedGuestIdentifierLeak() {
        let leak = BodyLowering.OpaqueLeaf(id: "op_1", source: "Color.red.frame(height: __geo_height)",
                                           slotable: true, label: "x")
        XCTAssertFalse(ThunkGenerator.viewThunkValidates(name: "V", slots: [leak], tokens: [], rowSlots: []))
        let ok = BodyLowering.OpaqueLeaf(id: "op_2", source: "Color.red.frame(height: 20)", slotable: true, label: "x")
        XCTAssertTrue(ThunkGenerator.viewThunkValidates(name: "V", slots: [ok], tokens: [], rowSlots: []))
        let tok = BodyLowering.HostToken(id: "nt_1", source: "__strtok_abc", kind: .string)
        XCTAssertFalse(ThunkGenerator.viewThunkValidates(name: "V", slots: [], tokens: [tok], rowSlots: []))
    }

    // MARK: - Bug 2: generated code must stay cheap for the type checker

    /// The SpeedToolPanel-shaped stress fixture: ~30 parameterized slots (custom child views with
    /// lifted literals + heavy modifier chains), an in-file helper block (a private member read)
    /// and a GeometryReader kept native as ONE slot. The prepared output must type-check, and no
    /// generated function body may come anywhere near the type checker's budget (measured:
    /// `__patchSlots()` ≈ 50 ms on Swift 6.0.2 — the same order as the original body).
    func testThirtySlotPanelWithGeometrySlotTypeChecksCheaply() throws {
        var rows: [String] = []
        for i in 0..<30 {
            rows.append("""
                            Chip(title: "Preset \(i)", detail: "x\(i)", selected: model.speed > \(i).5)
                                .padding(.horizontal, model.speed > \(i) ? 8 : 4)
                                .opacity(model.keepPitch ? 1 : 0.6)
                                .cardChrome()
            """)
        }
        let groups = stride(from: 0, to: 30, by: 10).map {
            "            VStack(alignment: .leading, spacing: 6) {\n" + rows[$0..<($0 + 10)].joined(separator: "\n") + "\n            }"
        }.joined(separator: "\n")
        let src = """
        import SwiftUI
        final class EditorModel: ObservableObject {
            @Published var speed: Double = 1
            @Published var keepPitch = true
        }
        struct Chip: View {
            let title: String
            let detail: String
            let selected: Bool
            var body: some View { HStack { Text(title); Text(detail) } }
        }
        extension View {
            func cardChrome() -> some View { self.padding(6).background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.15))) }
        }
        struct BigPanel: View {
            @ObservedObject var model: EditorModel
            @State private var dragging = false
            var body: some View {
                ScrollView {
        \(groups)
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.15)).frame(height: 6)
                            Circle()
                                .fill(Color.white)
                                .frame(width: dragging ? 26 : 20, height: dragging ? 26 : 20)
                                .offset(x: max(0, min(geometry.size.width * CGFloat((model.speed - 0.25) / 3.75) - 10, geometry.size.width - 20)))
                                .cardChrome()
                        }
                        .frame(height: max(28, min(geometry.size.height * 0.40, 44)))
                    }
                    .frame(height: 44)
                }
            }
        }
        """
        guard let o = try Self.prepareHybridAndCompile(["BigPanel.swift": src],
                                                       extraFlags: ["-Xfrontend", "-debug-time-function-bodies"]) else {
            throw XCTSkip("no iphonesimulator SDK")
        }
        XCTAssertTrue(o.compiled, "prepared output must type-check:\n\(o.log.prefix(4000))")
        let slotCount = o.all.components(separatedBy: "__s[\"").count - 1
        XCTAssertGreaterThanOrEqual(slotCount, 25, "fixture must exercise many slots (got \(slotCount))")
        XCTAssertFalse(o.all.contains("__geo_"))
        // Generated closures carry an explicit `-> AnyView` result type and no `?:` join.
        XCTAssertFalse(o.all.contains("a.count >= 1 ? AnyView("), "parameterized slots use the guard form")
        // Slowest generated helper body (debug-time-function-bodies: `<ms>ms\t<file:line:col>\t<decl>`).
        let generatedMs = o.log.split(separator: "\n").compactMap { line -> Double? in
            let cols = line.split(separator: "\t")
            guard cols.count >= 3, cols[0].hasSuffix("ms"), cols[2].contains("__patch") else { return nil }
            return Double(cols[0].dropLast(2))
        }
        XCTAssertFalse(generatedMs.isEmpty, "expected timing lines for the generated helpers")
        XCTAssertLessThan(generatedMs.max() ?? 0, 3000,
                          "a generated helper body is approaching the type-checker budget: \(generatedMs)")
    }
}
