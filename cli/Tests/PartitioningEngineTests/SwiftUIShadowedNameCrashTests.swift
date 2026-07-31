// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CodeGenerator

/// A view may LEGALLY shadow a name — e.g. a `static let foo` and a `@State var foo`. The
/// view's `inputs` then carry a duplicate name, and `buildStateModel` used to key them via
/// `Dictionary(uniqueKeysWithValues:)`, which TRAPS on a duplicate key. Unlike a normal
/// demote, a runtime trap inside lowering has NO backstop — it aborts the whole app's module
/// build. This was observed on real apps (exyte-Chat `maxSelectionRowWidth`, NetNewsWire
/// `model`). Lowering such a view must NOT crash.
final class SwiftUIShadowedNameCrashTests: XCTestCase {

    func testShadowedStaticAndStateNameDoesNotCrashLowering() {
        // A static constant and a @State var of the SAME name + an interaction that mutates
        // it (so a mutation rule is collected and `buildStateModel` runs over the duplicate).
        let source = """
        import SwiftUI
        struct ReactionSelectionView: View {
            static let maxSelectionRowWidth: CGFloat = 320
            @State private var maxSelectionRowWidth: CGFloat = 0
            var body: some View {
                Button("Tap") { maxSelectionRowWidth = 10 }
            }
        }
        """
        // The bug was a hard trap inside buildStateModel; the assertion is simply that
        // lowering RETURNS (any result) rather than crashing the process.
        let lowered = BodyLowering().lowerAllViews(source: source)
        XCTAssertFalse(lowered.isEmpty,
                       "a view shadowing a name must still lower without trapping; got \(lowered.count) views")
    }
}
