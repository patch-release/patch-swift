import XCTest
import WasmKit
@testable import PatchSDK

/// MapsDirectionsBridge — `patch.maps_open(json) -> i32`. The opener is injected,
/// so tests inject a spy that records the built URL. Three layers:
///   1. `parse(_:)` — request JSON → Request (or nil), tested directly.
///   2. `buildURL(_:)` — Request → canonical maps.apple.com URL, tested directly.
///   3. `openPayload(_:)` — the parse→build→open path the host fn runs, with a spy.
/// No real UIKit / wasm fixture required.
final class MapsDirectionsBridgeTests: XCTestCase {

    private typealias Bridge = MapsDirectionsBridge

    // MARK: - parse

    func testParseCoordinateDestination() throws {
        let req = try XCTUnwrap(Bridge.parse(Array(#"{"destLat":37.33,"destLng":-122.03}"#.utf8)))
        XCTAssertEqual(req.destLat, 37.33)
        XCTAssertEqual(req.destLng, -122.03)
        XCTAssertNil(req.destAddress)
        XCTAssertEqual(req.mode, "driving", "mode defaults to driving")
    }

    func testParseAddressDestination() throws {
        let req = try XCTUnwrap(Bridge.parse(Array(#"{"destAddress":"1 Infinite Loop"}"#.utf8)))
        XCTAssertEqual(req.destAddress, "1 Infinite Loop")
        XCTAssertNil(req.destLat)
    }

    func testParseWithSourceAndMode() throws {
        let json = #"{"destLat":37.33,"destLng":-122.03,"srcLat":37.78,"srcLng":-122.41,"mode":"walking"}"#
        let req = try XCTUnwrap(Bridge.parse(Array(json.utf8)))
        XCTAssertEqual(req.srcLat, 37.78)
        XCTAssertEqual(req.srcLng, -122.41)
        XCTAssertEqual(req.mode, "walking")
    }

    func testParseRejectsNoDestination() {
        XCTAssertNil(Bridge.parse(Array(#"{"mode":"driving"}"#.utf8)), "no dest → nil")
        XCTAssertNil(Bridge.parse(Array(#"{"destLat":37.33}"#.utf8)), "lat without lng → nil")
        XCTAssertNil(Bridge.parse(Array(#"{"destAddress":"  "}"#.utf8)), "blank address → nil")
        XCTAssertNil(Bridge.parse(Array("not json".utf8)))
    }

    func testNormalizeMode() {
        XCTAssertEqual(Bridge.normalizeMode("walking"), "walking")
        XCTAssertEqual(Bridge.normalizeMode("WALK"), "walking")
        XCTAssertEqual(Bridge.normalizeMode("transit"), "transit")
        XCTAssertEqual(Bridge.normalizeMode("r"), "transit")
        XCTAssertEqual(Bridge.normalizeMode("driving"), "driving")
        XCTAssertEqual(Bridge.normalizeMode(nil), "driving")
        XCTAssertEqual(Bridge.normalizeMode("nonsense"), "driving")
    }

    // MARK: - buildURL

    func testBuildURLForCoordinate() throws {
        let req = try XCTUnwrap(Bridge.parse(Array(#"{"destLat":37,"destLng":-122}"#.utf8)))
        let url = try XCTUnwrap(Bridge.buildURL(req))
        XCTAssertTrue(url.hasPrefix("https://maps.apple.com/?"), "got \(url)")
        XCTAssertTrue(url.contains("daddr=37,-122"), "got \(url)")
        XCTAssertTrue(url.contains("dirflg=d"), "driving → d; got \(url)")
    }

    func testBuildURLForAddressPercentEncodes() throws {
        let req = try XCTUnwrap(Bridge.parse(Array(#"{"destAddress":"1 Infinite Loop, Cupertino"}"#.utf8)))
        let url = try XCTUnwrap(Bridge.buildURL(req))
        // Spaces/commas in the address must be percent-encoded into the query.
        XCTAssertTrue(url.contains("daddr=1%20Infinite%20Loop") || url.contains("daddr=1+Infinite+Loop"),
                      "address must be encoded; got \(url)")
        XCTAssertFalse(url.contains("daddr=1 Infinite"), "raw spaces must not appear; got \(url)")
    }

    func testBuildURLWithSourceAndWalkingFlag() throws {
        let json = #"{"destLat":1,"destLng":2,"srcLat":3,"srcLng":4,"mode":"walking"}"#
        let req = try XCTUnwrap(Bridge.parse(Array(json.utf8)))
        let url = try XCTUnwrap(Bridge.buildURL(req))
        XCTAssertTrue(url.contains("daddr=1,2"), "got \(url)")
        XCTAssertTrue(url.contains("saddr=3,4"), "got \(url)")
        XCTAssertTrue(url.contains("dirflg=w"), "walking → w; got \(url)")
    }

    func testBuildURLTransitFlag() throws {
        let req = try XCTUnwrap(Bridge.parse(Array(#"{"destAddress":"Airport","mode":"transit"}"#.utf8)))
        let url = try XCTUnwrap(Bridge.buildURL(req))
        XCTAssertTrue(url.contains("dirflg=r"), "transit → r; got \(url)")
    }

    /// The built URL is a real, parseable URL.
    func testBuiltURLIsValid() throws {
        let req = try XCTUnwrap(Bridge.parse(Array(#"{"destLat":37.33,"destLng":-122.03}"#.utf8)))
        let url = try XCTUnwrap(Bridge.buildURL(req))
        XCTAssertNotNil(URL(string: url))
    }

    // MARK: - Dispatch through a spy opener

    private final class OpenSpy: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var opened: [String] = []
        private let result: Bool
        init(result: Bool = true) { self.result = result }
        var open: Bridge.Opener {
            { [self] url in lock.lock(); opened.append(url); lock.unlock(); return result }
        }
    }

    /// A valid request builds a URL and hands it to the opener; success → 1.
    func testOpenPayloadDispatchesBuiltURL() {
        let spy = OpenSpy(result: true)
        let bridge = Bridge(open: spy.open)
        let rc = bridge.openPayload(Array(#"{"destLat":37,"destLng":-122}"#.utf8))
        XCTAssertEqual(rc, 1)
        XCTAssertEqual(spy.opened.count, 1)
        XCTAssertTrue(spy.opened[0].contains("daddr=37,-122"))
    }

    /// An invalid request returns 0 WITHOUT consulting the opener.
    func testOpenPayloadInvalidRequestSkipsOpener() {
        let spy = OpenSpy()
        let bridge = Bridge(open: spy.open)
        XCTAssertEqual(bridge.openPayload(Array("not json".utf8)), 0)
        XCTAssertEqual(bridge.openPayload(Array(#"{"mode":"driving"}"#.utf8)), 0)
        XCTAssertTrue(spy.opened.isEmpty, "invalid requests must not reach the opener")
    }

    /// Opener failure returns 0 (but was consulted).
    func testOpenPayloadOpenerFailureReturnsZero() {
        let spy = OpenSpy(result: false)
        let bridge = Bridge(open: spy.open)
        XCTAssertEqual(bridge.openPayload(Array(#"{"destLat":1,"destLng":2}"#.utf8)), 0)
        XCTAssertEqual(spy.opened.count, 1)
    }

    // MARK: - Bridge shape / registration

    func testModuleNamespaceAndRegistration() {
        let bridge = Bridge(open: { _ in true })
        XCTAssertEqual(bridge.module, "patch")
        XCTAssertNotNil(BridgeRegistry().register(bridge).hostImports())
    }

    #if canImport(UIKit)
    func testDefaultInitRegisters() {
        XCTAssertNotNil(BridgeRegistry().register(MapsDirectionsBridge()).hostImports())
    }
    #endif
}
