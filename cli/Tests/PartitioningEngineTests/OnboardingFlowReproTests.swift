// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
@testable import CodeGenerator
import ViewNodeIR

/// DIAGNOSTIC (AppA OnboardingFlow title-edit MISMATCH). Lowers the exact view
/// and prints the demote/bake decision so we know the precise gate before fixing.
final class OnboardingFlowReproTests: XCTestCase {
    func testDiagnoseOnboardingFlow() throws {
        let src = #"""
        import SwiftUI
        struct OnboardingFlow: View {
            let onComplete: () -> Void
            @State private var page: Int = 0
            private let totalPages = 2
            dynamic var body: some View {
                VStack(spacing: 0) {
                    HStack {
                        ProgressDots(total: 3, index: page)
                        Spacer()
                        Button("Skip") { onComplete() }
                            .font(Theme.Font.body(14))
                            .foregroundStyle(Theme.Colors.muted)
                            .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 60)
                    Spacer()
                    switch page {
                    case 0:
                        onboardingContent(illustration: AnyView(Onboard1Illustration(width: 304)), title: "Find MY best\ntime to post.", body: "We learn when your audience is most active and tell you the moment to hit publish.")
                    default:
                        onboardingContent(illustration: AnyView(Onboard2Illustration(width: 304)), title: "Plan the YEAR,\nnever miss a window.", body: "Soft reminders ping you before each peak. You decide the rhythm.")
                    }
                    Spacer()
                    PillButton(title: "Continue", icon: "arrow.right", variant: .primary) {
                        if page < totalPages - 1 { page += 1 } else { onComplete() }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
                }
                .screenBackground()
            }
            @ViewBuilder
            private func onboardingContent(illustration: AnyView, title: String, body: String) -> some View {
                VStack(spacing: 28) {
                    illustration
                    VStack(alignment: .leading, spacing: 12) {
                        DisplayText(text: title, size: 36)
                        BodyText(text: body)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 28)
            }
        }
        """#
        let views = BodyLowering().lowerAllViews(source: src, sameFileThunk: true)
        let v = try XCTUnwrap(views.first(where: { $0.viewName == "OnboardingFlow" }))
        print("=== ONBOARDINGFLOW_DIAG_START ===")
        print("DIAG referencesUnmarshalledInput:", v.referencesUnmarshalledInput)
        print("DIAG referencesUnresolvedSymbol:", v.referencesUnresolvedSymbol)
        print("DIAG unresolvedSymbols:", v.unresolvedSymbols)
        print("DIAG blockingReadNames:", v.blockingReadNames)
        print("DIAG hasUndispatchableAction:", v.hasUndispatchableAction)
        print("DIAG hasUndispatchableEffect:", v.hasUndispatchableEffect)
        print("DIAG inputs:", v.inputs.map { "\($0.name):\($0.kind)" })
        print("DIAG opaqueLeaves count:", v.opaqueLeaves.count)
        for l in v.opaqueLeaves {
            print("DIAG LEAF id=\(l.id) slotable=\(l.slotable) label=\(l.label) src<=120=\(l.source.replacingOccurrences(of: "\n", with: " ").prefix(120))")
        }
        print("DIAG actionSlots:", v.actionSlots.map { $0.id })
        print("DIAG title in a LEAF source:", v.opaqueLeaves.contains { $0.source.contains("Find MY best") })
        print("DIAG title in guestBody:", v.guestBody.contains("Find MY best"))
        print("DIAG guestBody<=400:", v.guestBody.replacingOccurrences(of: "\n", with: " ").prefix(400))
        print("=== ONBOARDINGFLOW_DIAG_END ===")
        // REGRESSION (cli 1.6.31 fix): the title literal must be LIFTED (ride WASM as a
        // stringArg), NOT baked into native slot source — so editing it is OTA-deliverable
        // (no FINGERPRINT MISMATCH). This is the user-reported bug, proven fixed at the
        // engine level (the E2E oracle proves it on a real prod app).
        let bakedInLeaf = v.opaqueLeaves.contains { $0.source.contains("Find MY best") }
        XCTAssertFalse(bakedInLeaf, "OnboardingFlow title must be LIFTED, not baked in slot source")
        let liftedArgs = v.opaqueLeaves.flatMap { $0.stringArgs }
        XCTAssertTrue(liftedArgs.contains { $0.contains("Find MY best") },
            "OnboardingFlow title must appear in the leaf's lifted stringArgs (got \(liftedArgs))")
    }

    private func diag(_ tag: String, _ src: String) {
        let views = BodyLowering().lowerAllViews(source: src, sameFileThunk: true)
        guard let v = views.first(where: { $0.viewName == "V" }) else { print("DIAGB \(tag): NO VIEW"); return }
        let leafLabels = v.opaqueLeaves.map { $0.label.replacingOccurrences(of: "\n", with: " ").prefix(24) }
        print("DIAGB \(tag): leaves=\(v.opaqueLeaves.count) refUnmarsh=\(v.referencesUnmarshalledInput) undisp=\(v.hasUndispatchableAction) titleInGuest=\(v.guestBody.contains("HELLO")) leafLabels=\(leafLabels) guest<=160=\(v.guestBody.replacingOccurrences(of: "\n", with: " ").prefix(160))")
    }

    /// CASE B — a `switch` STATEMENT as a CHILD of a VStack (with sibling Texts). Hypothesis:
    /// the whole VStack slots to one opaque leaf (so "HELLO" never rides WASM).
    func testSwitchAsContainerChild() {
        diag("switchChild", #"""
        import SwiftUI
        struct V: View {
            @State private var page: Int = 0
            var body: some View {
                VStack {
                    Text("HELLO")
                    switch page { case 0: Text("a"); default: Text("b") }
                    Text("world")
                }
            }
        }
        """#)
    }

    /// CASE C — an `if` STATEMENT as a CHILD of a VStack.
    func testIfAsContainerChild() {
        diag("ifChild", #"""
        import SwiftUI
        struct V: View {
            @State private var page: Int = 0
            var body: some View {
                VStack {
                    Text("HELLO")
                    if page == 0 { Text("a") } else { Text("b") }
                    Text("world")
                }
            }
        }
        """#)
    }

    /// CASE D — closure property + Button/leaf, NO switch. Does "HELLO" ride WASM?
    func testClosurePropNoSwitch() {
        diag("closureNoSwitch", #"""
        import SwiftUI
        struct V: View {
            let onComplete: () -> Void
            var body: some View {
                VStack {
                    Text("HELLO")
                    Button("Skip") { onComplete() }
                }
            }
        }
        """#)
    }

    /// CASE F — custom MODIFIER on the container (`.screenBackground()`). Does it slot the whole VStack?
    func testCustomModifierOnContainer() {
        diag("customMod", #"""
        import SwiftUI
        struct V: View {
            var body: some View {
                VStack { Text("HELLO"); Text("world") }.screenBackground()
            }
        }
        """#)
    }

    /// CASE G — Spacer() children + switch, no custom modifier (onboarding minus screenBackground).
    func testSpacersAndSwitch() {
        diag("spacersSwitch", #"""
        import SwiftUI
        struct V: View {
            let onComplete: () -> Void
            @State private var page: Int = 0
            var body: some View {
                VStack(spacing: 0) {
                    HStack { Spacer(); Button("Skip") { onComplete() } }.padding(.horizontal, 28)
                    Spacer()
                    switch page { case 0: Text("HELLO"); default: Text("b") }
                    Spacer()
                }
            }
        }
        """#)
    }

    /// CASE E — switch child whose arms call a CUSTOM helper (the OnboardingFlow shape).
    func testSwitchChildCustomHelper() {
        diag("switchHelper", #"""
        import SwiftUI
        struct V: View {
            @State private var page: Int = 0
            var body: some View {
                VStack {
                    Text("HELLO")
                    switch page { case 0: row(title: "a"); default: row(title: "b") }
                }
            }
            @ViewBuilder private func row(title: String) -> some View { Text(title) }
        }
        """#)
    }
}
