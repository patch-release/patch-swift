import XCTest
@testable import PatchSDK

/// Verifies the SDK populates the release-targeting client facts (`os_version` /
/// `app_version`) that the backend's `update_check` compares against a release's
/// `min_app_version` / `max_app_version` / `min_os_version`. Without these the
/// backend fails open and version targeting is inert.
final class ReleaseTargetingFactsTests: XCTestCase {

    /// `Patch.osVersion` must be a non-empty, semver-shaped string on the host so
    /// the backend can compare it numerically (it parses with a semver regex).
    func testOSVersionIsNonEmptySemverShaped() {
        let os = Patch.osVersion
        XCTAssertFalse(os.isEmpty, "os_version must be non-empty for targeting to work")

        // Must be dot-separated numeric components (e.g. "17.4" or "14.5.0"),
        // which is what the backend's numeric-semver comparison expects.
        let components = os.split(separator: ".")
        XCTAssertGreaterThanOrEqual(components.count, 2,
            "expected at least major.minor, got \(os)")
        for part in components {
            XCTAssertNotNil(Int(part), "non-numeric semver component in \(os): \(part)")
        }
    }

    /// `os_version` / `app_version` set on the request must survive JSON
    /// encode/decode under the exact snake_case keys the backend pydantic model
    /// reads — i.e. the wire format is unchanged.
    func testTargetingFactsRoundTripUnderSnakeCaseKeys() throws {
        let req = UpdateCheckRequest(
            current_version: "1.0.0",
            fingerprint: "fp",
            device_id: "dev",
            app_id: "11111111-1111-1111-1111-111111111111",
            os_version: "17.4",
            app_version: "2.1.0",
            sdk_version: Patch.sdkVersion)

        let data = try JSONEncoder().encode(req)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        // Exact backend-facing keys.
        XCTAssertEqual(obj["os_version"] as? String, "17.4")
        XCTAssertEqual(obj["app_version"] as? String, "2.1.0")

        let decoded = try JSONDecoder().decode(UpdateCheckRequest.self, from: data)
        XCTAssertEqual(decoded.os_version, "17.4")
        XCTAssertEqual(decoded.app_version, "2.1.0")
    }

    /// The app-assigned `cohort` must encode under the backend `cohort` key so a
    /// release with `--target-cohort beta` can filter on it. It is optional and
    /// defaults to nil (backward compatible — old payloads simply omit it).
    func testCohortRoundTripsUnderBackendKey() throws {
        let req = UpdateCheckRequest(
            current_version: "1.0.0",
            fingerprint: "fp",
            device_id: "dev",
            app_id: "11111111-1111-1111-1111-111111111111",
            cohort: "beta")
        let data = try JSONEncoder().encode(req)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["cohort"] as? String, "beta")

        let decoded = try JSONDecoder().decode(UpdateCheckRequest.self, from: data)
        XCTAssertEqual(decoded.cohort, "beta")
    }

    /// `cohort` defaults to nil when the app does not set one (the backend then
    /// derives a hash-bucket cohort from `device_id`).
    func testCohortDefaultsToNil() {
        let req = UpdateCheckRequest(
            current_version: "1.0.0", fingerprint: "fp",
            device_id: "dev", app_id: "app")
        XCTAssertNil(req.cohort)
    }

    /// A cohort set on the `PatchConfiguration` is carried verbatim and is nil by
    /// default, matching the wire field the SDK sends on every update check.
    func testConfigurationCarriesCohort() {
        let withCohort = PatchConfiguration(appKey: "k", cohort: "internal")
        XCTAssertEqual(withCohort.cohort, "internal")
        let none = PatchConfiguration(appKey: "k")
        XCTAssertNil(none.cohort)
        // The channelName convenience initializer also accepts a cohort.
        let viaName = PatchConfiguration(
            appKey: "k", channelName: "staging", cohort: "qa")
        XCTAssertEqual(viaName.cohort, "qa")
        XCTAssertEqual(viaName.channelName, "staging")
    }
}
