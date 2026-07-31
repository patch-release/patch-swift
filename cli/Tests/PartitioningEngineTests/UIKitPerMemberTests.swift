// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PartitioningEngine

/// UIKit "Phase 1a": free pure-logic methods INSIDE a UIViewController/UIView/cell
/// subclass to be OTA-patchable, instead of the old blanket force-native. Two
/// themes, mirroring the engine's safety contract (and `SwiftUIValueLiftTests`):
///   1. COVERAGE — a pure value/computation method (formatter, reducer, layout
///      math) on a UIKit VC/View is now `wasmEligible`/`bridged`.
///   2. SAFETY (zero false negatives, THE CARDINAL INVARIANT) — any method that
///      touches UIKit (a native type/API, `self.<native-typed/@IBOutlet property>`,
///      `@objc`/`@IBAction`/`#selector`/`dynamic`, or a lifecycle override) STILL
///      classifies native. The relaxation only ever REMOVES the blanket flag and
///      re-runs the unchanged native scans, so it is strictly more-conservative-or-
///      equal in what it frees — it can only lose coverage, never gain a false
///      negative.
final class UIKitPerMemberTests: XCTestCase {
    private func classify(_ source: String) -> [String: ClassificationResult] {
        let records = SwiftParserEngine().parse(source: source, file: Fixtures.fixtureURL)
        let g = CallGraphBuilder().build(from: records)
        return Classifier().classifyAll(g)
    }

    /// Match a result by the id's FINAL path component (or `Type.member` for a
    /// dotted query). Mirrors `SwiftUIValueLiftTests.result` so closure ids that
    /// embed enclosing names as a prefix don't collide.
    private func result(_ results: [String: ClassificationResult], containing query: String) -> ClassificationResult? {
        let wantQualified = query.contains(".")
        return results.first { key, _ in
            let comps = key.split(separator: ".").map(String.init)
            guard let last = comps.last else { return false }
            let memberName = last.split(separator: "(").first.map(String.init) ?? last
            if wantQualified {
                guard comps.count >= 2 else { return false }
                let qualified = "\(comps[comps.count - 2]).\(memberName)"
                return qualified == query
            }
            return memberName == query
        }?.value
    }

    // ========================================================================
    // MARK: - COVERAGE — pure methods on a UIKit VC are now freed
    // ========================================================================

    /// The worked example from the mandate: a VC with a pure `formatPrice`, a pure
    /// reducer, and pure layout math → all wasmEligible; the lifecycle override and
    /// the UIKit-touching methods → still native.
    private static let pricingVC = """
    import UIKit
    final class PricingViewController: UIViewController {
        @IBOutlet var totalLabel: UILabel!
        let tableView = UITableView()
        var prices: [Int] = []
        var discount: Double = 0.1

        // ---- PURE VALUE / LOGIC — should be FREED ----
        func formatPrice(_ cents: Int) -> String {
            let dollars = Double(cents) / 100.0
            return "$" + String(format: "%.2f", dollars)
        }
        func subtotal(_ items: [Int]) -> Int {
            return items.reduce(0, +)
        }
        func discounted(_ total: Int) -> Int {
            return Int(Double(total) * (1.0 - discount))
        }
        func rowHeight(for index: Int) -> CGFloat {
            return index == 0 ? 64 : 44
        }
        static func clamp(_ x: Int, lo: Int, hi: Int) -> Int {
            return min(max(x, lo), hi)
        }

        // ---- MUST STAY NATIVE ----
        override func viewDidLoad() {
            super.viewDidLoad()
            tableView.dataSource = nil
        }
    }
    """

    func testPureMethodsOnUIVCAreFreed() {
        let r = classify(Self.pricingVC)
        for frag in ["formatPrice", "subtotal", "discounted", "rowHeight", "clamp"] {
            XCTAssertEqual(result(r, containing: frag)?.classification, .wasmEligible,
                           "\(frag) is a pure value/logic method on a UIViewController → should be FREED to wasmEligible. " +
                           "reasons: \(result(r, containing: frag)?.reasons ?? [])")
        }
    }

    /// `discount` here is a plain `Double` stored property — NOT native — so the
    /// methods reading it stay eligible (proves we don't over-force on every `self`
    /// property, only native-typed/wrapped ones).
    func testReadingPlainValueStoredPropertyStaysEligible() {
        let r = classify(Self.pricingVC)
        XCTAssertEqual(result(r, containing: "discounted")?.classification, .wasmEligible,
                       "reading a plain Double stored property (`discount`) must NOT force native")
    }

    /// A pure method on a `UIView` subclass (layout math) is freed too.
    func testPureMethodOnUIViewSubclassIsFreed() {
        let src = """
        import UIKit
        final class GaugeView: UIView {
            func angle(for value: Double, min: Double, max: Double) -> Double {
                let t = (value - min) / (max - min)
                return -90 + t * 180
            }
        }
        """
        let r = classify(src)
        XCTAssertEqual(result(r, containing: "angle")?.classification, .wasmEligible,
                       "pure layout math on a UIView subclass → freed")
    }

    /// A pure method on a `UITableViewCell` subclass is freed.
    func testPureMethodOnCellSubclassIsFreed() {
        let src = """
        import UIKit
        final class PriceCell: UITableViewCell {
            func badge(_ count: Int) -> String {
                if count <= 0 { return "" }
                return count > 99 ? "99+" : "\\(count)"
            }
        }
        """
        let r = classify(src)
        XCTAssertEqual(result(r, containing: "badge")?.classification, .wasmEligible,
                       "pure value method on a UITableViewCell subclass → freed")
    }

    /// A method on a UIVC that uses only a BRIDGEABLE leaf (UserDefaults) + pure
    /// logic is now `bridged` (runs OTA) — previously blanket-native.
    func testBridgeableOnlyMethodOnUIVCIsBridged() {
        let src = """
        import UIKit
        final class SettingsVC: UIViewController {
            func persistedCount() -> Int {
                return UserDefaults.standard.integer(forKey: "count") * 2
            }
        }
        """
        let r = classify(src)
        let res = result(r, containing: "persistedCount")
        XCTAssertNotEqual(res?.classification, .native,
                          "a UserDefaults-only method on a UIVC should run OTA (bridged), not native")
        XCTAssertEqual(res?.classification, .bridged,
                       "UserDefaults-only + pure logic on a UIVC → bridged. reasons: \(res?.reasons ?? [])")
    }

    // ========================================================================
    // MARK: - SAFETY — UIKit-touching methods STILL native (zero false negatives)
    // ========================================================================

    /// (b) A method referencing a UIKit TYPE/API stays native (registry mustStayNative).
    func testMethodTouchingUIKitTypeStaysNative() {
        let src = """
        import UIKit
        final class VC: UIViewController {
            // Constructs a UIColor — a mustStayNative symbol.
            func makeTint() -> UIColor { return UIColor(white: 0.5, alpha: 1) }
            // Calls view.addSubview — touches the native view tree via `view`.
            func addBanner() {
                let banner = UILabel()
                view.addSubview(banner)
            }
        }
        """
        let r = classify(src)
        XCTAssertNotEqual(result(r, containing: "makeTint")?.classification, .wasmEligible,
                          "ZERO-FALSE-NEGATIVE: constructing UIColor must never be wasmEligible")
        XCTAssertNotEqual(result(r, containing: "addBanner")?.classification, .wasmEligible,
                          "ZERO-FALSE-NEGATIVE: UILabel()/addSubview must never be wasmEligible")
    }

    /// (a) A method touching a NATIVE-TYPED stored property (`self.tableView` where
    /// `tableView` is a `UITableView`) stays native — even though `reloadData` and
    /// the bare identifier `tableView` are NOT registry symbols. This is the gap the
    /// new native-typed-property collection closes.
    func testMethodTouchingNativeTypedStoredPropertyStaysNative() {
        let src = """
        import UIKit
        final class VC: UIViewController {
            let tableView = UITableView()
            let countLabel: UILabel = UILabel()
            func refresh() {
                tableView.reloadData()
            }
            func bump() {
                self.tableView.reloadData()
            }
            func annotatedProp() {
                countLabel.text = "x"
            }
        }
        """
        let r = classify(src)
        XCTAssertNotEqual(result(r, containing: "refresh")?.classification, .wasmEligible,
                          "ZERO-FALSE-NEGATIVE: touching a UITableView-typed property (init-inferred) must be native")
        XCTAssertNotEqual(result(r, containing: "bump")?.classification, .wasmEligible,
                          "ZERO-FALSE-NEGATIVE: self.tableView.reloadData() must be native")
        XCTAssertNotEqual(result(r, containing: "annotatedProp")?.classification, .wasmEligible,
                          "ZERO-FALSE-NEGATIVE: touching a UILabel-annotated property must be native")
    }

    /// A method reading a COMPUTED property that is native stays native, whether the
    /// computed property declares a native return type OR its getter touches native
    /// state (a native-typed stored property / a registry symbol). A reader sees only
    /// the bare property name, so the property name itself must be recorded native.
    func testReadingNativeComputedPropertyStaysNative() {
        let src = """
        import UIKit
        final class VC: UIViewController {
            let label = UILabel()
            // (i) computed with native RETURN TYPE.
            var spinner: UIActivityIndicatorView { UIActivityIndicatorView() }
            // (ii) computed with no native annotation but getter touches `label` (UILabel).
            var caption: String { label.text ?? "" }
            // (iii) computed reading the native registry symbol UIScreen directly.
            var screenWidth: CGFloat { UIScreen.main.bounds.width }

            func readsSpinner() -> Bool { return spinner.isAnimating }
            func readsCaption() -> Int { return caption.count }
            func readsScreen() -> CGFloat { return screenWidth / 2 }
        }
        """
        let r = classify(src)
        XCTAssertNotEqual(result(r, containing: "readsSpinner")?.classification, .wasmEligible,
                          "ZERO-FALSE-NEGATIVE: reading a native-typed computed property must be native")
        XCTAssertNotEqual(result(r, containing: "readsCaption")?.classification, .wasmEligible,
                          "ZERO-FALSE-NEGATIVE: reading a computed property whose getter touches a UILabel must be native")
        XCTAssertNotEqual(result(r, containing: "readsScreen")?.classification, .wasmEligible,
                          "ZERO-FALSE-NEGATIVE: reading a computed property whose getter touches UIScreen must be native")
    }

    /// `Type.init()` / qualified `Module.Type()` stored-property initializers are
    /// recognised as native too (not just the bare `Type()` form).
    func testStoredPropertyInitFormsRecognised() {
        let src = """
        import UIKit
        final class VC: UIViewController {
            let a = UITableView.init()
            let b = UIKit.UILabel()
            func usesA() { a.reloadData() }
            func usesB() { b.text = "x" }
        }
        """
        let r = classify(src)
        XCTAssertNotEqual(result(r, containing: "usesA")?.classification, .wasmEligible,
                          "ZERO-FALSE-NEGATIVE: UITableView.init() property must keep reader native")
        XCTAssertNotEqual(result(r, containing: "usesB")?.classification, .wasmEligible,
                          "ZERO-FALSE-NEGATIVE: UIKit.UILabel() property must keep reader native")
    }

    /// (c) A method touching an `@IBOutlet`-backed property stays native (the outlet
    /// wrapper marks the property native via `nativePropertyNames`).
    func testMethodTouchingIBOutletStaysNative() {
        let src = """
        import UIKit
        final class VC: UIViewController {
            @IBOutlet weak var nameField: UITextField!
            func clearName() {
                nameField.text = ""
            }
        }
        """
        let r = classify(src)
        XCTAssertNotEqual(result(r, containing: "clearName")?.classification, .wasmEligible,
                          "ZERO-FALSE-NEGATIVE: touching an @IBOutlet property must be native")
    }

    /// (d) `@objc` / `@IBAction` / `#selector` / `dynamic` members stay native.
    func testObjcAndSelectorAndDynamicStayNative() {
        let src = """
        import UIKit
        final class VC: UIViewController {
            @objc func tapped() {
                let _ = 2 + 2
            }
            @IBAction func save(_ sender: Any) {
                let _ = 1
            }
            dynamic func reload() {
                let _ = 3
            }
            func wire() {
                let b = UIButton()
                b.addTarget(self, action: #selector(tapped), for: .touchUpInside)
            }
        }
        """
        let r = classify(src)
        XCTAssertEqual(result(r, containing: "tapped")?.classification, .native,
                       "ZERO-FALSE-NEGATIVE: @objc handler must be native")
        XCTAssertEqual(result(r, containing: "save")?.classification, .native,
                       "ZERO-FALSE-NEGATIVE: @IBAction must be native")
        XCTAssertEqual(result(r, containing: "reload")?.classification, .native,
                       "ZERO-FALSE-NEGATIVE: dynamic method must be native")
        XCTAssertNotEqual(result(r, containing: "wire")?.classification, .wasmEligible,
                          "ZERO-FALSE-NEGATIVE: a #selector wiring site (+ UIButton) must be native")
    }

    /// (e) UIKit lifecycle overrides stay native even when their body looks pure.
    func testLifecycleOverridesStayNative() {
        let src = """
        import UIKit
        final class VC: UIViewController {
            // Bodies deliberately touch NO registry symbol — only the lifecycle-name
            // rule keeps them native.
            override func viewDidLoad() {
                let _ = 1 + 1
            }
            override func viewWillAppear(_ animated: Bool) {
                let _ = animated ? 1 : 0
            }
        }
        final class CardView: UIView {
            override func layoutSubviews() {
                let _ = 2 * 2
            }
            override func draw(_ rect: CGRect) {
                let _ = 3
            }
            override func sizeThatFits(_ size: CGSize) -> CGSize {
                return size
            }
        }
        final class Cell: UITableViewCell {
            override func prepareForReuse() {
                let _ = 0
            }
        }
        """
        let r = classify(src)
        for frag in ["viewDidLoad", "viewWillAppear", "layoutSubviews", "draw",
                     "sizeThatFits", "prepareForReuse"] {
            XCTAssertEqual(result(r, containing: frag)?.classification, .native,
                           "ZERO-FALSE-NEGATIVE: UIKit lifecycle override \(frag) must stay native. " +
                           "reasons: \(result(r, containing: frag)?.reasons ?? [])")
        }
    }

    /// A method whose SIGNATURE takes a native type (a UIView param) stays native
    /// even if its body only does bare member calls on it.
    func testMethodWithNativeParamTypeStaysNative() {
        let src = """
        import UIKit
        final class VC: UIViewController {
            func style(_ label: UILabel) {
                label.numberOfLines = 0
            }
        }
        """
        let r = classify(src)
        XCTAssertNotEqual(result(r, containing: "style")?.classification, .wasmEligible,
                          "ZERO-FALSE-NEGATIVE: a UILabel parameter must keep the method native")
    }

    /// A method reading a reactive wrapper on a UIVC is NEVER `wasmEligible`. A
    /// pure read of a VALUE-MARSHALLABLE reactive prop is host-projected → `mixed`
    /// (the shell projects the value into the WASM fragment); a read of a
    /// NATIVE-typed reactive prop stays native (the value can't be marshalled).
    func testReactiveWrapperOnUIVCIsProjectedOrNative() {
        let src = """
        import UIKit
        import Combine
        final class VC: UIViewController {
            @Published var count: Int = 0
            @Published var badge: UILabel? = nil
            func label() -> String { return "count: \\(count)" }   // value-typed @Published → host-projected
            func badgeText() -> String { return badge?.text ?? "" } // native-typed @Published → native
        }
        """
        let r = classify(src)
        let label = result(r, containing: "label")?.classification
        XCTAssertNotEqual(label, .wasmEligible,
                          "ZERO-FALSE-NEGATIVE: reading @Published on a UIVC must never be wasmEligible")
        XCTAssertEqual(label, .mixed,
                       "pure read of a value-typed @Published on a UIVC → host-projected (mixed)")
        XCTAssertEqual(result(r, containing: "badgeText")?.classification, .native,
                       "reading a NATIVE-typed @Published (UILabel?) must stay native — not marshallable")
    }

    /// THE KEY INHERITED-SURFACE SAFETY: a UIKit VC/View method that touches the
    /// INHERITED native surface — `self.view`, `navigationController`, `dismiss(…)`,
    /// `present(…)`, `addSubview(…)`, anchors, or any `super.<uikitMethod>()` — stays
    /// native even though none of those is declared on the subclass or is a registry
    /// symbol. The old blanket force masked this entire class; relaxing it without
    /// this guard would be a mass false negative.
    func testInheritedUIKitSurfaceStaysNative() {
        let src = """
        import UIKit
        final class VC: UIViewController {
            func a() { super.setNeedsStatusBarAppearanceUpdate() }
            func usesView() -> Int { return view.tag }
            func nav() { navigationController?.popViewController(animated: true) }
            func close() { dismiss(animated: true) }
            func add() { let l = view; l?.layoutIfNeeded() }
            func anchorWork() {
                let g = view.safeAreaLayoutGuide
                _ = g.topAnchor
            }
        }
        final class CardView: UIView {
            func mount(_ child: CardView) { addSubview(child) }
            func relayout() { setNeedsLayout() }
        }
        """
        let r = classify(src)
        for frag in ["VC.a", "usesView", "nav", "close", "add", "anchorWork",
                     "mount", "relayout"] {
            XCTAssertNotEqual(result(r, containing: frag)?.classification, .wasmEligible,
                              "ZERO-FALSE-NEGATIVE: \(frag) touches the inherited UIKit surface / super → must be native. " +
                              "reasons: \(result(r, containing: frag)?.reasons ?? [])")
        }
    }

    /// The inherited-surface guard is scoped to UIKit view/VC types ONLY — a plain
    /// (non-UIKit) type with a method named `view`/`show`/`present` is unaffected and
    /// classifies on its merits. (Proves the guard doesn't leak outside UIKit types.)
    func testInheritedSurfaceGuardScopedToUIKitTypes() {
        let src = """
        struct Router {
            func present(_ id: Int) -> Int { return id + 1 }
            func show(_ x: Int) -> Int { return x * 2 }
        }
        """
        let r = classify(src)
        XCTAssertEqual(result(r, containing: "Router.present")?.classification, .wasmEligible,
                       "a plain struct's `present` helper must not be force-native by the UIKit guard")
        XCTAssertEqual(result(r, containing: "Router.show")?.classification, .wasmEligible,
                       "a plain struct's `show` helper must not be force-native by the UIKit guard")
    }

    /// A pure method that CALLS a native lifecycle/method sibling becomes (at most)
    /// mixed/native — never wasmEligible — because the native callee is a boundary.
    func testCallingNativeSiblingIsNotWasmEligible() {
        let src = """
        import UIKit
        final class VC: UIViewController {
            let tableView = UITableView()
            func reloadIfNeeded(_ shouldReload: Bool) {
                if shouldReload { tableView.reloadData() }
            }
        }
        """
        let r = classify(src)
        XCTAssertNotEqual(result(r, containing: "reloadIfNeeded")?.classification, .wasmEligible,
                          "ZERO-FALSE-NEGATIVE: a method touching the native tableView property is not eligible")
    }

    // ========================================================================
    // MARK: - The carve-out is EXACT (the three-way table from the mandate)
    // ========================================================================

    /// One VC exercising all three classes side by side: (1) pure → wasmEligible,
    /// (2) touches `self.tableView`/`addSubview`/`@IBOutlet` → native,
    /// (3) `viewDidLoad`/`@objc` → native. Proves the carve-out is exact.
    func testExactCarveOut() {
        let src = """
        import UIKit
        final class FeedViewController: UIViewController {
            @IBOutlet var headerLabel: UILabel!
            let tableView = UITableView()
            var items: [String] = []
            var page = 0

            // (1) PURE — wasmEligible
            func formatCount(_ n: Int) -> String { return n == 1 ? "1 item" : "\\(n) items" }
            func nextPage() -> Int { return page + 1 }

            // (2) NATIVE — touches view tree / outlet
            func reload() { tableView.reloadData() }
            func setHeader(_ s: String) { headerLabel.text = s }
            func addSpinner() { let s = UIActivityIndicatorView(); view.addSubview(s) }

            // (3) NATIVE — lifecycle / @objc
            override func viewDidLoad() { super.viewDidLoad(); let _ = page }
            @objc func pull() { let _ = nextPage() }
        }
        """
        let r = classify(src)
        // (1)
        XCTAssertEqual(result(r, containing: "formatCount")?.classification, .wasmEligible)
        XCTAssertEqual(result(r, containing: "nextPage")?.classification, .wasmEligible)
        // (2)
        XCTAssertNotEqual(result(r, containing: "reload")?.classification, .wasmEligible)
        XCTAssertNotEqual(result(r, containing: "setHeader")?.classification, .wasmEligible)
        XCTAssertNotEqual(result(r, containing: "addSpinner")?.classification, .wasmEligible)
        // (3)
        XCTAssertEqual(result(r, containing: "viewDidLoad")?.classification, .native)
        XCTAssertEqual(result(r, containing: "pull")?.classification, .native)
    }
}
