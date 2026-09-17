// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
@testable import CodeGenerator
import ViewNodeIR

/// `if #available(…) { A } else { B }` is the ONE construct the lowering resolves by DELETING a
/// branch: it emits `A` and drops `B`, because the device running an OTA patch meets the SDK's
/// deployment floor. The only thing that keeps an OLDER device faithful is the manifest `minOS`
/// the engine stamps from the condition — below it the SDK renders the native body (which runs
/// the developer's real `#available` and so takes `B`).
///
/// That makes the pairing load-bearing: **a condition we resolve MUST produce a minOS on every
/// platform it names.** If it doesn't, the gate does not exist and the patched view renders `A`
/// on a device whose native code renders `B` — a wrong render, invisible to the developer. The
/// safe answer for an unmodelled platform is not to resolve at all: the whole `if` becomes a
/// native slot, and BOTH branches render from the app's own `#available`.
final class SwiftUIAvailabilityResolutionTests: XCTestCase {

    private func view(_ body: String, name: String = "V") -> BodyLowering.LoweredView? {
        BodyLowering().lowerAllViews(source: """
        import SwiftUI
        struct \(name): View {
            let title: String
            var body: some View {
                VStack {
                    \(body)
                }
            }
        }
        """, sameFileThunk: true).first { $0.viewName == name }
    }

    /// A MODELLED platform still resolves (the coverage this path exists for) and stamps minOS.
    func testModelledPlatformResolvesAndStampsMinOS() {
        guard let v = view(#"if #available(iOS 17.0, *) { Text("new") } else { Text("old") }"#) else {
            return XCTFail("no view")
        }
        XCTAssertEqual(v.resolvedAvailability, ["#available(iOS 17.0, *)"])
        XCTAssertEqual(BodyLowering.minimumOS(fromAvailabilityConditions: v.resolvedAvailability),
                       ["iOS": "17.0"])
        XCTAssertTrue(v.guestBody.contains(#"N.text("new")"#), v.guestBody)
        XCTAssertFalse(v.guestBody.contains(#"N.text("old")"#), v.guestBody)
    }

    /// AN UNMODELLED PLATFORM (`macCatalyst` — `minimumOS` maps it to nothing) must NOT resolve.
    /// Resolving it would drop the `else` with no minOS to keep an old macCatalyst device on the
    /// native body.
    func testUnmodelledPlatformDoesNotResolveTheBranch() {
        guard let v = view(#"if #available(macCatalyst 16.0, *) { Text("new") } else { Text("old") }"#) else {
            return XCTFail("no view")
        }
        XCTAssertEqual(v.resolvedAvailability, [],
                       "a condition with no derivable minOS must not be resolved")
        XCTAssertFalse(v.guestBody.contains(#"N.text("new")"#),
                       "the available branch must not be lowered in place of the whole `if`:\n\(v.guestBody)")
        // Both branches survive natively, inside one slot the app's own `#available` drives.
        let slotted = v.opaqueLeaves.map(\.source).joined(separator: "\n")
        XCTAssertTrue(slotted.contains("#available(macCatalyst 16.0, *)"), slotted)
        XCTAssertTrue(slotted.contains("else"), "the `else` branch must survive in the native slot:\n\(slotted)")
    }

    /// A MIXED condition is only as safe as its weakest platform: `iOS` alone would gate, but the
    /// unmodelled `macCatalyst` term leaves that platform ungated, so the whole condition is
    /// unresolvable.
    func testMixedConditionWithOneUnmodelledPlatformDoesNotResolve() {
        guard let v = view(#"if #available(iOS 17.0, macCatalyst 16.0, *) { Text("new") } else { Text("old") }"#) else {
            return XCTFail("no view")
        }
        XCTAssertEqual(v.resolvedAvailability, [])
        XCTAssertFalse(v.guestBody.contains(#"N.text("new")"#), v.guestBody)
    }

    /// An UNPARSEABLE version is the same hole (`minimumOS` skips the spec), so it must not resolve.
    func testUnparseableVersionDoesNotResolve() {
        guard let v = view(#"if #available(iOS 17.0.0.1, *) { Text("new") } else { Text("old") }"#) else {
            return XCTFail("no view")
        }
        XCTAssertEqual(v.resolvedAvailability, [])
    }

    /// `#unavailable` was already never resolved — pin it (its inverse would take the `else`).
    func testUnavailableIsNeverResolved() {
        guard let v = view(#"if #unavailable(iOS 17.0) { Text("new") } else { Text("old") }"#) else {
            return XCTFail("no view")
        }
        XCTAssertEqual(v.resolvedAvailability, [])
    }

    /// EVERY resolved condition, by construction, yields a minOS — the invariant the SDK's gate
    /// depends on.
    func testEveryResolvedConditionYieldsAMinOS() {
        for condition in ["iOS 17.0", "macOS 14.0", "tvOS 16.0", "watchOS 9.0", "visionOS 1.0",
                          "iOS 17.0, macOS 14.0", "macCatalyst 16.0", "iOS 17, macCatalyst 16.0"] {
            guard let v = view("if #available(\(condition), *) { Text(\"new\") } else { Text(\"old\") }") else {
                return XCTFail("no view for \(condition)")
            }
            for resolved in v.resolvedAvailability {
                XCTAssertFalse(BodyLowering.minimumOS(fromAvailabilityConditions: [resolved]).isEmpty,
                               "resolved `\(resolved)` with no minOS — the older-OS gate would not exist")
            }
        }
    }
}
