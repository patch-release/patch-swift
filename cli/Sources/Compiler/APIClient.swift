// SPDX-License-Identifier: Apache-2.0

import Foundation
import CryptoKit

/// A reference box so a semaphore-bridged URLSession completion handler can hand
/// its result back to the calling thread under Swift 6 strict concurrency: the
/// semaphore orders the single write strictly before the read, so `@unchecked
/// Sendable` is sound. Shared by the synchronous HTTP wrappers (APIClient + the
/// `channels` command).
public final class SyncResultBox<T>: @unchecked Sendable {
    public var result: Result<T, Error>?
    public init() {}
}

// MARK: - Wire types (mirror backend schemas)

/// The backend-stored native-shell component breakdown (the `components` field of
/// a registered fingerprint). Mirrors `ProjectFingerprinter.componentsDictionary`.
/// All fields are optional because a record registered by an OLDER CLI may omit the
/// newer per-file lists — the diff degrades gracefully (category-level) when they
/// are absent. Used to show WHICH components/files changed on a fingerprint
/// mismatch, instead of just two opaque hashes.
public struct StoredFingerprintComponents: Sendable, Equatable {
    public let sdkVersion: String?
    public let wasmKitVersion: String?
    public let bridgeDefinitions: [String]?
    public let linkedFrameworks: [String]?
    public let deploymentTarget: String?
    public let swiftCompilerVersion: String?
    public let nativeSwiftFileCount: Int?
    public let nativeGeneratedStubCount: Int?
    /// Category label → hash (always present; enables category-level diffing).
    public let componentHashes: [String: String]?
    /// Per-file "relpath|hash" entries — present only on registrations made by a
    /// CLI new enough to store them, so file-level naming is available going forward.
    public let nativeSwiftFiles: [String]?
    public let nativeGeneratedStubs: [String]?

    public init(
        sdkVersion: String?, wasmKitVersion: String?, bridgeDefinitions: [String]?,
        linkedFrameworks: [String]?, deploymentTarget: String?, swiftCompilerVersion: String?,
        nativeSwiftFileCount: Int?, nativeGeneratedStubCount: Int?,
        componentHashes: [String: String]?, nativeSwiftFiles: [String]?, nativeGeneratedStubs: [String]?
    ) {
        self.sdkVersion = sdkVersion; self.wasmKitVersion = wasmKitVersion
        self.bridgeDefinitions = bridgeDefinitions; self.linkedFrameworks = linkedFrameworks
        self.deploymentTarget = deploymentTarget; self.swiftCompilerVersion = swiftCompilerVersion
        self.nativeSwiftFileCount = nativeSwiftFileCount
        self.nativeGeneratedStubCount = nativeGeneratedStubCount
        self.componentHashes = componentHashes
        self.nativeSwiftFiles = nativeSwiftFiles; self.nativeGeneratedStubs = nativeGeneratedStubs
    }
}

/// Returned by `POST /fingerprints` and `GET /fingerprints/{app_id}`.
public struct FingerprintRecord: Sendable, Equatable {
    public let id: String          // DB UUID — referenced by module uploads
    public let appId: String
    public let fingerprint: String // the SHA-256 hash string
    public let isActive: Bool
    public let appVersion: String?
    /// The stored component breakdown (when the backend returns it) — used to
    /// explain a fingerprint mismatch component-by-component.
    public let components: StoredFingerprintComponents?

    public init(id: String, appId: String, fingerprint: String, isActive: Bool,
                appVersion: String?, components: StoredFingerprintComponents? = nil) {
        self.id = id; self.appId = appId; self.fingerprint = fingerprint
        self.isActive = isActive; self.appVersion = appVersion
        self.components = components
    }
}

/// Returned by `GET /api/v1/apps` (provisioning). The CLI uses this to resolve
/// `app_id` (and `workspace_id`) from the app's bundle id when they are not
/// already pinned in `.Patch.yml`. The secret `app_key` is intentionally NOT
/// part of this (the backend omits it from list/get responses).
public struct AppRecord: Sendable, Equatable {
    public let id: String
    public let workspaceId: String
    public let name: String
    public let bundleId: String
    public let platform: String

    public init(id: String, workspaceId: String, name: String, bundleId: String, platform: String) {
        self.id = id; self.workspaceId = workspaceId; self.name = name
        self.bundleId = bundleId; self.platform = platform
    }
}

/// Returned by module upload / list / rollout / rollback.
public struct ModuleRecord: Sendable, Equatable {
    public let id: String
    public let appId: String
    public let version: String
    public let channel: String
    public let sha256: String
    public let sizeBytes: Int
    public let rolloutPct: Int
    public let mandatory: Bool
    public let isActive: Bool
    public let releaseNotes: String?
    public let modulePath: String        // module_gcs_path (the .br path — see note)
    public let pushedAt: String
    public let rolledBackAt: String?
    // Release targeting echoed back by the backend (nil = targets everyone).
    public let minAppVersion: String?
    public let maxAppVersion: String?
    public let minOsVersion: String?
    public let targetCohort: String?

    public init(id: String, appId: String, version: String, channel: String, sha256: String,
                sizeBytes: Int, rolloutPct: Int, mandatory: Bool, isActive: Bool,
                releaseNotes: String?, modulePath: String, pushedAt: String, rolledBackAt: String?,
                minAppVersion: String? = nil, maxAppVersion: String? = nil,
                minOsVersion: String? = nil, targetCohort: String? = nil) {
        self.id = id; self.appId = appId; self.version = version; self.channel = channel
        self.sha256 = sha256; self.sizeBytes = sizeBytes; self.rolloutPct = rolloutPct
        self.mandatory = mandatory; self.isActive = isActive; self.releaseNotes = releaseNotes
        self.modulePath = modulePath; self.pushedAt = pushedAt; self.rolledBackAt = rolledBackAt
        self.minAppVersion = minAppVersion; self.maxAppVersion = maxAppVersion
        self.minOsVersion = minOsVersion; self.targetCohort = targetCohort
    }

    /// A one-line human summary of targeting, or nil when this module targets
    /// everyone. E.g. "app ≥ 2.1.0, app ≤ 3.0.0, iOS ≥ 16.0, cohort beta".
    public var targetingSummary: String? {
        var parts: [String] = []
        if let minAppVersion { parts.append("app ≥ \(minAppVersion)") }
        if let maxAppVersion { parts.append("app ≤ \(maxAppVersion)") }
        if let minOsVersion { parts.append("iOS ≥ \(minOsVersion)") }
        if let targetCohort { parts.append("cohort \(targetCohort)") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

/// Pure decision logic for `Patch rollback --to <version>`.
///
/// The CLI rolls back the active module repeatedly until `target` becomes active
/// (the backend re-activates the most recent OTHER module on each rollback). If
/// `target` is NEWER than the active version (so it can never be reached by rolling
/// BACK) — or the backend cycles — the loop must NOT keep firing destructive
/// rollbacks: each one demotes a real release. `stalled` detects no-progress (the
/// just-activated version was already rolled THROUGH) so the loop stops early
/// instead of damaging the release history and misreporting the result.
public enum RollbackPlan {
    /// True iff rolling back is NOT making progress toward a new version: the
    /// version that just became active was already seen (a cycle / unreachable
    /// target). Side-effect-free except for inserting into the caller's `seen` set,
    /// so the reachability guard is unit-testable without a live API.
    public static func stalled(seen: inout Set<String>, nowActive: String) -> Bool {
        !seen.insert(nowActive).inserted
    }
}

/// Returned by `GET /modules/{id}/stats`.
public struct ModuleStats: Sendable, Equatable {
    public let moduleId: String
    public let version: String
    public let downloads: Int
    public let activations: Int
    public let errors: Int

    public init(moduleId: String, version: String, downloads: Int, activations: Int, errors: Int) {
        self.moduleId = moduleId; self.version = version
        self.downloads = downloads; self.activations = activations; self.errors = errors
    }

    /// Failure rate = errors / (activations + errors). 0 when no signal yet.
    public var failureRate: Double {
        let denom = activations + errors
        return denom > 0 ? Double(errors) / Double(denom) : 0
    }
    /// Adoption proxy = activations / downloads.
    public var adoptionRate: Double {
        downloads > 0 ? Double(activations) / Double(downloads) : 0
    }
}

/// Returned by `GET /api/v1/cli/entitlements?workspace_id=…` (API-key authed).
///
/// The plan + feature flags + upgrade affordances the CLI uses to PRE-CHECK a
/// paid-only rollout BEFORE the expensive WASM build (B3). Mirrors the backend
/// `CliEntitlements` schema. `upgradeAbMsg` / `upgradeChannelMsg` are the verbatim
/// 402 messages the upload endpoint would have returned, so the CLI prints the
/// SAME text + URL when it fails fast.
public struct Entitlements: Sendable, Equatable {
    public let plan: String
    public let isPaid: Bool
    public let canAbTest: Bool
    public let canUseChannels: Bool
    public let upgradeURL: String
    public let upgradeAbMsg: String
    public let upgradeChannelMsg: String

    public init(plan: String, isPaid: Bool, canAbTest: Bool, canUseChannels: Bool,
                upgradeURL: String, upgradeAbMsg: String, upgradeChannelMsg: String) {
        self.plan = plan; self.isPaid = isPaid
        self.canAbTest = canAbTest; self.canUseChannels = canUseChannels
        self.upgradeURL = upgradeURL
        self.upgradeAbMsg = upgradeAbMsg; self.upgradeChannelMsg = upgradeChannelMsg
    }
}

/// Client-side pre-check for paid-only rollouts (B3).
///
/// The CLI used to run the FULL WASM build and only discover the plan can't do a
/// phased rollout / non-prod channel when the upload 402'd — wasting a compile on
/// the free tier. This pure decision logic lets the push/ship flow check the
/// plan BEFORE building and fail fast with the same message the server returns.
///
/// Two pure functions, both side-effect-free and unit-testable without a build:
///   - `requiresPaidPlan(channel:rollout:)` — does the request ask for anything
///     paid-only? Drives whether we even make the round-trip (the common path —
///     rollout 100 on production — returns false → NO extra network call).
///   - `upgradeMessage(channel:rollout:entitlements:)` — given the resolved
///     entitlements, the upgrade message to fail with, or `nil` to proceed.
public enum PaidRolloutPrecheck {
    /// The full-rollout percentage; anything else is a phased / A-B rollout.
    public static let fullRolloutPct = 100
    /// The one channel every plan may ship to.
    public static let defaultChannel = "production"

    /// True iff the request asks for a paid-only feature (a non-100 rollout, or a
    /// non-production channel). When false, the common path, NO entitlements
    /// round-trip is needed and the push proceeds with zero added latency.
    public static func requiresPaidPlan(channel: String, rollout: Int) -> Bool {
        rollout != fullRolloutPct || channel != defaultChannel
    }

    /// The upgrade message to FAIL FAST with for this request given the resolved
    /// entitlements, or `nil` when the plan is allowed to proceed.
    ///
    /// Mirrors the server's precedence in `POST /modules`: the A-B (rollout) gate
    /// is evaluated before the channel gate, so a hobby user doing
    /// `--rollout 25 --channel beta` sees the rollout upgrade message — exactly
    /// what the upload would have returned.
    public static func upgradeMessage(channel: String, rollout: Int,
                                      entitlements: Entitlements) -> String? {
        if rollout != fullRolloutPct && !entitlements.canAbTest {
            return entitlements.upgradeAbMsg
        }
        if channel != defaultChannel && !entitlements.canUseChannels {
            return entitlements.upgradeChannelMsg
        }
        return nil
    }
}

/// Metadata sent in a module upload (matches backend `ModuleMetadata`).
public struct ModuleUploadMetadata: Sendable, Equatable {
    public var appId: String
    public var workspaceId: String
    public var version: String
    public var fingerprintId: String
    public var channel: String
    public var mandatory: Bool
    public var rolloutPct: Int
    public var releaseNotes: String?
    // Optional release targeting (absent / nil = no constraint = targets
    // everyone, identical to prior behavior). Encoded into the metadata JSON
    // ONLY when set. Keys mirror backend `ModuleMetadata`:
    // `min_app_version`, `max_app_version`, `min_os_version`, `target_cohort`.
    public var minAppVersion: String?
    public var maxAppVersion: String?
    public var minOsVersion: String?
    public var targetCohort: String?

    public init(appId: String, workspaceId: String, version: String, fingerprintId: String,
                channel: String = "production", mandatory: Bool = false,
                rolloutPct: Int = 100, releaseNotes: String? = nil,
                minAppVersion: String? = nil, maxAppVersion: String? = nil,
                minOsVersion: String? = nil, targetCohort: String? = nil) {
        self.appId = appId; self.workspaceId = workspaceId; self.version = version
        self.fingerprintId = fingerprintId; self.channel = channel; self.mandatory = mandatory
        self.rolloutPct = rolloutPct; self.releaseNotes = releaseNotes
        self.minAppVersion = minAppVersion; self.maxAppVersion = maxAppVersion
        self.minOsVersion = minOsVersion; self.targetCohort = targetCohort
    }

    func jsonString() -> String {
        var obj: [String: Any] = [
            "app_id": appId,
            "workspace_id": workspaceId,
            "version": version,
            "fingerprint_id": fingerprintId,
            "channel": channel,
            "mandatory": mandatory,
            "rollout_pct": rolloutPct,
        ]
        if let releaseNotes { obj["release_notes"] = releaseNotes }
        // Targeting keys are omitted entirely when nil so an un-targeted upload
        // sends exactly the same metadata it always has.
        if let minAppVersion { obj["min_app_version"] = minAppVersion }
        if let maxAppVersion { obj["max_app_version"] = maxAppVersion }
        if let minOsVersion { obj["min_os_version"] = minOsVersion }
        if let targetCohort { obj["target_cohort"] = targetCohort }
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

// MARK: - Errors

public enum APIError: Error, CustomStringConvertible {
    case transport(String)
    case http(status: Int, body: String)
    case decoding(String)
    case notConfigured(String)

    public var description: String {
        switch self {
        case .transport(let m): return "Network error: \(m)"
        case .http(let s, let b): return "Backend returned HTTP \(s): \(b)"
        case .decoding(let m): return "Could not decode backend response: \(m)"
        case .notConfigured(let m): return m
        }
    }
}

// MARK: - Protocol (injectable / mockable)

public protocol PatchAPI: Sendable {
    /// Resolve an app by its bundle id via `GET /api/v1/apps?bundle_id=...`.
    /// Returns nil when no app with that bundle id exists.
    func lookupApp(bundleId: String) throws -> AppRecord?
    func registerFingerprint(appId: String, fingerprint: String, components: [String: Any],
                             appVersion: String?) throws -> FingerprintRecord
    func getActiveFingerprint(appId: String) throws -> FingerprintRecord?
    /// Resolve the workspace's plan + entitlements via
    /// `GET /api/v1/cli/entitlements?workspace_id=…`. Used to pre-check a
    /// paid-only rollout BEFORE building (B3).
    func entitlements(workspaceId: String) throws -> Entitlements
    /// Upload the app's primary icon to `POST /api/v1/apps/{app_id}/icon`
    /// (multipart `file`), so the console can display it. Best-effort: callers
    /// SKIP on any failure (a missing endpoint / network error must never fail the
    /// command). Returns the served icon URL/path the backend stored it at, when
    /// the response carries one.
    func uploadAppIcon(appId: String, icon: Data, fileName: String, mimeType: String) throws -> String?
    func uploadModule(metadata: ModuleUploadMetadata, wasm: Data) throws -> ModuleRecord
    func listModules(appId: String, channel: String?) throws -> [ModuleRecord]
    func updateRollout(moduleID: String, rolloutPct: Int) throws -> ModuleRecord
    func rollback(moduleID: String) throws -> ModuleRecord
    func stats(moduleID: String) throws -> ModuleStats
}

// MARK: - Real URLSession client

/// Talks to the real Patch backend over HTTP with CLI-token (`X-API-Key`) auth.
/// Synchronous (blocking on a semaphore) because the CLI is a one-shot tool; no
/// async ceremony needed. Base URL + key come from `.Patch.yml`/env at the call
/// site and are injected here.
public struct HTTPPatchAPI: PatchAPI {
    public let baseURL: URL
    public let apiKey: String
    public let session: URLSession
    public let timeout: TimeInterval

    public init(baseURL: URL, apiKey: String, session: URLSession = .shared, timeout: TimeInterval = 30) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
        self.timeout = timeout
    }

    /// Normalize a backend base URL to its ROOT (scheme://host[:port]), dropping a
    /// trailing `/api/v1` (or `/api/v1/`) so the CLI can append `api/v1/...` exactly
    /// once.
    ///
    /// The canonical production URL the SDK + docs publish is
    /// `https://api.patchrelease.com/api/v1` — a developer who pastes THAT verbatim
    /// into `.Patch.yml`'s `api_base_url` (or `--base-url`) used to get
    /// `…/api/v1/api/v1/modules`, so EVERY networked command 404'd with an opaque
    /// error. We now tolerate both the bare root and the `…/api/v1` form. Exposed
    /// `static` so it is unit-testable without a live `URLSession` and shared with
    /// the `channels` command's direct GET.
    public static func normalizedBase(_ url: URL) -> URL {
        // Trim trailing slashes, then a single trailing `/api/v1` path suffix.
        var s = url.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        for suffix in ["/api/v1", "/api"] where s.hasSuffix(suffix) {
            s.removeLast(suffix.count)
            break
        }
        return URL(string: s) ?? url
    }

    private func apiURL(_ path: String) -> URL {
        Self.normalizedBase(baseURL).appendingPathComponent("api/v1").appendingPathComponent(path)
    }

    // ---- Apps ---------------------------------------------------------------

    public func lookupApp(bundleId: String) throws -> AppRecord? {
        var comps = URLComponents(url: apiURL("apps"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "bundle_id", value: bundleId)]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        do {
            let json = try send(req)
            // The endpoint returns a single-item list for a bundle_id lookup.
            guard let arr = json as? [[String: Any]], let first = arr.first else { return nil }
            return decodeApp(first)
        } catch APIError.http(let status, _) where status == 404 {
            return nil
        }
    }

    // ---- Fingerprints -------------------------------------------------------

    public func registerFingerprint(appId: String, fingerprint: String, components: [String: Any],
                                     appVersion: String?) throws -> FingerprintRecord {
        var body: [String: Any] = [
            "app_id": appId,
            "fingerprint": fingerprint,
            "components": components,
        ]
        if let appVersion { body["app_version"] = appVersion }
        let data = try JSONSerialization.data(withJSONObject: body)
        let json = try sendJSON(method: "POST", url: apiURL("fingerprints"), jsonBody: data)
        return try decodeFingerprint(json)
    }

    public func getActiveFingerprint(appId: String) throws -> FingerprintRecord? {
        do {
            let json = try sendJSON(method: "GET", url: apiURL("fingerprints/\(appId)"), jsonBody: nil)
            return try decodeFingerprint(json)
        } catch APIError.http(let status, _) where status == 404 {
            return nil
        }
    }

    // ---- Entitlements (CLI pre-check) ---------------------------------------

    public func entitlements(workspaceId: String) throws -> Entitlements {
        var comps = URLComponents(url: apiURL("cli/entitlements"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "workspace_id", value: workspaceId)]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        let json = try send(req)
        return try decodeEntitlements(json)
    }

    // ---- App icon -----------------------------------------------------------

    /// Upload the app icon to `POST /api/v1/apps/{app_id}/icon` as multipart
    /// form-data (field name `file`), API-key authed. Returns the served URL/path
    /// when the response carries one (`icon_url` / `url` / `icon_path`), else nil.
    /// The CLI treats any thrown error as "skip" — see `Init`/`PushFlow`.
    public func uploadAppIcon(appId: String, icon: Data, fileName: String, mimeType: String) throws -> String? {
        let boundary = "PatchBoundary-\(UUID().uuidString)"
        var req = URLRequest(url: apiURL("apps/\(appId)/icon"))
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var data = Data()
        func append(_ s: String) { data.append(s.data(using: .utf8)!) }
        append("--\(boundary)\r\n")
        // A quoted filename containing `"` or CR/LF would break the header; the
        // icon's basename is filesystem-derived so sanitize defensively.
        let safeName = fileName.replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeName.isEmpty ? "icon.png" : safeName)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        data.append(icon)
        append("\r\n")
        append("--\(boundary)--\r\n")
        req.httpBody = data

        let json = try send(req)
        guard let obj = json as? [String: Any] else { return nil }
        return str(obj["icon_url"]) ?? str(obj["url"]) ?? str(obj["icon_path"])
    }

    // ---- Modules ------------------------------------------------------------

    /// Resolve the module-upload timeout (seconds): `PATCH_UPLOAD_TIMEOUT` env when
    /// set (and a positive number), else the larger of the per-call default and a
    /// 600s floor. Large modules + slow links must never spuriously time out (the
    /// retry-creates-a-duplicate P1). Exposed `static` so it is unit-testable
    /// without a live `URLSession`.
    public static func uploadTimeout(default base: TimeInterval) -> TimeInterval {
        let floor: TimeInterval = 600
        if let raw = ProcessInfo.processInfo.environment["PATCH_UPLOAD_TIMEOUT"],
           let v = TimeInterval(raw), v > 0 {
            return v
        }
        return max(base, floor)
    }

    public func uploadModule(metadata: ModuleUploadMetadata, wasm: Data) throws -> ModuleRecord {
        // Small modules go straight over multipart (one request). LARGE modules use a
        // DIRECT-to-storage upload — request a one-time upload URL, PUT the bytes
        // straight to storage, then finalize — to bypass the API's request-size limit
        // (Cloud Run caps requests at 32 MiB; a full-Foundation module 413'd the old
        // multipart path). The resumable path falls back to multipart when the backend
        // has no direct route (501 — local dev / an older server).
        //
        // 24 MiB threshold: keeps a comfortable margin under the 32 MiB cap for
        // multipart's boundary overhead, and avoids an extra upload-URL round-trip for
        // the common small-module case.
        let resumableThreshold = 24 * 1024 * 1024
        if wasm.count > resumableThreshold {
            let sha = Self.sha256Hex(wasm)
            if let record = try uploadModuleResumable(metadata: metadata, wasm: wasm, sha256: sha) {
                return record
            }
        }
        return try uploadModuleMultipart(metadata: metadata, wasm: wasm)
    }

    /// Direct-to-storage upload. Returns nil when the backend has no direct path
    /// (the caller then falls back to multipart); throws on a genuine failure.
    private func uploadModuleResumable(
        metadata: ModuleUploadMetadata, wasm: Data, sha256: String
    ) throws -> ModuleRecord? {
        // 1. Ask for an upload URL.
        let reqBody = try JSONSerialization.data(withJSONObject: [
            "app_id": metadata.appId, "sha256": sha256, "size_bytes": wasm.count,
        ])
        let urlJSON: Any
        do {
            urlJSON = try sendJSON(
                method: "POST", url: apiURL("modules/upload-url"), jsonBody: reqBody)
        } catch APIError.http(let status, _) where status == 501 || status == 404 || status == 405 {
            return nil  // no direct-upload path → fall back to multipart
        }
        guard let obj = urlJSON as? [String: Any],
              let uploadURLStr = str(obj["upload_url"]),
              let uploadURL = URL(string: uploadURLStr),
              let stagingKey = str(obj["staging_key"]) else {
            return nil  // unexpected shape → fall back
        }
        // 2. PUT the raw bytes straight to storage (single-shot resumable session;
        //    the session URI is its own credential, so NO X-API-Key here).
        try putBytes(to: uploadURL, data: wasm)
        // 3. Finalize: the server reads the staged bytes, verifies sha256, registers.
        guard let metaDict = try JSONSerialization.jsonObject(
            with: Data(metadata.jsonString().utf8)) as? [String: Any] else {
            throw APIError.decoding("could not re-encode module metadata")
        }
        let finalizeBody = try JSONSerialization.data(withJSONObject: [
            "metadata": metaDict, "staging_key": stagingKey, "sha256": sha256,
        ])
        let json = try sendJSON(
            method: "POST", url: apiURL("modules/finalize"), jsonBody: finalizeBody)
        return try decodeModule(json)
    }

    /// Resumable PUT of `data` to a storage upload-session URI (GCS resumable
    /// session semantics). A single transient blip must NOT fail the whole release:
    ///   - GCS replies 308 "Resume Incomplete" while bytes are still owed — this is
    ///     NORMAL, not an error, so it must not throw. We read the committed offset
    ///     (the `Range` header, `bytes=0-<end>`) and re-PUT the remaining tail.
    ///   - On a transport error or 308 we retry with backoff up to `maxAttempts`,
    ///     each time first querying the session for the committed offset so we resume
    ///     from where it left off rather than re-sending the whole body.
    /// Completion is 200/201. The session URI is its own credential (no X-API-Key).
    private func putBytes(to url: URL, data: Data) throws {
        let n = data.count
        let maxAttempts = 5
        var offset = 0
        var lastError: Error = APIError.transport("upload did not complete")

        for attempt in 0..<maxAttempts {
            do {
                let (_, http) = try sendRaw(uploadChunkRequest(url: url, data: data, from: offset, total: n))
                let status = http.statusCode
                if (200..<300).contains(status) { return }  // upload complete
                if status == 308 {
                    // Resume Incomplete: advance to the committed offset and continue.
                    offset = Self.committedOffset(from: http) ?? offset
                    lastError = APIError.http(status: 308, body: "resume incomplete at offset \(offset)")
                    continue
                }
                // A genuine 4xx/5xx — surface it (idempotent: a later retry re-uploads).
                throw APIError.http(status: status, body: "")
            } catch let err as APIError {
                lastError = err
                // Before retrying, ask the session how many bytes it actually committed
                // so we resume from the right place (best-effort).
                if attempt + 1 < maxAttempts, let committed = querySessionOffset(url: url, total: n) {
                    offset = committed
                }
            } catch {
                lastError = APIError.transport(String(describing: error))
            }
            // Backoff before the next attempt (skip the wait after the final attempt).
            if attempt + 1 < maxAttempts {
                Thread.sleep(forTimeInterval: pow(2.0, Double(attempt)) * 0.5)
            }
        }
        throw lastError
    }

    /// Build a resumable-PUT request for the byte range `[from, total)`.
    private func uploadChunkRequest(url: URL, data: Data, from: Int, total: Int) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.timeoutInterval = Self.uploadTimeout(default: timeout)
        let start = max(0, min(from, total))
        let chunk = start < total ? data.subdata(in: start..<total) : Data()
        req.setValue("\(chunk.count)", forHTTPHeaderField: "Content-Length")
        if total > 0 {
            req.setValue("bytes \(start)-\(total - 1)/\(total)", forHTTPHeaderField: "Content-Range")
        } else {
            req.setValue("bytes */0", forHTTPHeaderField: "Content-Range")
        }
        req.setValue("application/wasm", forHTTPHeaderField: "Content-Type")
        req.httpBody = chunk
        return req
    }

    /// Query a resumable session for how many bytes it has committed: a zero-length
    /// PUT with `Content-Range: bytes */total`. GCS replies 308 with a `Range` header.
    /// Returns the next byte offset to send, or nil when it can't be determined.
    private func querySessionOffset(url: URL, total: Int) -> Int? {
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.timeoutInterval = timeout
        req.setValue("0", forHTTPHeaderField: "Content-Length")
        req.setValue("bytes */\(total)", forHTTPHeaderField: "Content-Range")
        guard let (_, http) = try? sendRaw(req) else { return nil }
        if (200..<300).contains(http.statusCode) { return total }  // already complete
        return Self.committedOffset(from: http)
    }

    /// Parse the committed offset from a GCS resumable `Range: bytes=0-<end>` header.
    /// The next byte to send is `end + 1`. Returns nil when absent/unparseable.
    private static func committedOffset(from http: HTTPURLResponse) -> Int? {
        guard let range = (http.value(forHTTPHeaderField: "Range")
                           ?? http.value(forHTTPHeaderField: "range")) else { return nil }
        // Format: "bytes=0-<end>".
        guard let dash = range.lastIndex(of: "-") else { return nil }
        let endStr = range[range.index(after: dash)...].trimmingCharacters(in: .whitespaces)
        guard let end = Int(endStr) else { return nil }
        return end + 1
    }

    /// The original multipart upload — used as a fallback (and on backends with no
    /// direct-upload path). The server-side store + brotli-compress can be slow, so
    /// the upload gets a long ceiling (overridable via PATCH_UPLOAD_TIMEOUT); the
    /// upload is sha256-idempotent so a retry is a no-op.
    private func uploadModuleMultipart(
        metadata: ModuleUploadMetadata, wasm: Data
    ) throws -> ModuleRecord {
        let boundary = "PatchBoundary-\(UUID().uuidString)"
        var req = URLRequest(url: apiURL("modules"))
        req.httpMethod = "POST"
        req.timeoutInterval = Self.uploadTimeout(default: timeout)
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var data = Data()
        func append(_ s: String) { data.append(s.data(using: .utf8)!) }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"metadata\"\r\n\r\n")
        append(metadata.jsonString())
        append("\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"module.wasm\"\r\n")
        append("Content-Type: application/octet-stream\r\n\r\n")
        data.append(wasm)
        append("\r\n")
        append("--\(boundary)--\r\n")
        req.httpBody = data

        let json = try send(req)
        return try decodeModule(json)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public func listModules(appId: String, channel: String?) throws -> [ModuleRecord] {
        var comps = URLComponents(url: apiURL("modules"), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "app_id", value: appId)]
        if let channel { items.append(URLQueryItem(name: "channel", value: channel)) }
        comps.queryItems = items
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        let json: Any
        do {
            json = try send(req)
        } catch APIError.http(let status, _) where status == 404 {
            // The backend now 404s an unknown app_id (instead of returning []), so a
            // typo'd id surfaces clearly here instead of masquerading as "0 modules".
            throw APIError.notConfigured(
                "App id `\(appId)` was not found on the backend.\n"
                + "Check `app_id:` in .Patch.yml (or `bundle_id:` for auto-resolution).")
        }
        guard let arr = json as? [[String: Any]] else {
            throw APIError.decoding("expected a JSON array of modules")
        }
        return try arr.map(decodeModule)
    }

    public func updateRollout(moduleID: String, rolloutPct: Int) throws -> ModuleRecord {
        let data = try JSONSerialization.data(withJSONObject: ["rollout_pct": rolloutPct])
        let json = try sendJSON(method: "PATCH", url: apiURL("modules/\(moduleID)/rollout"), jsonBody: data)
        return try decodeModule(json)
    }

    public func rollback(moduleID: String) throws -> ModuleRecord {
        let json = try sendJSON(method: "POST", url: apiURL("modules/\(moduleID)/rollback"), jsonBody: nil)
        return try decodeModule(json)
    }

    public func stats(moduleID: String) throws -> ModuleStats {
        let json = try sendJSON(method: "GET", url: apiURL("modules/\(moduleID)/stats"), jsonBody: nil)
        guard let obj = json as? [String: Any] else { throw APIError.decoding("stats not an object") }
        return ModuleStats(
            moduleId: str(obj["module_id"]) ?? moduleID,
            version: str(obj["version"]) ?? "",
            downloads: int(obj["downloads"]) ?? 0,
            activations: int(obj["activations"]) ?? 0,
            errors: int(obj["errors"]) ?? 0
        )
    }

    // ---- Transport ----------------------------------------------------------

    private func sendJSON(method: String, url: URL, jsonBody: Data?) throws -> Any {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        if let jsonBody {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = jsonBody
        }
        return try send(req)
    }

    /// Perform a request and return the raw `(Data, HTTPURLResponse)` WITHOUT
    /// status-checking or JSON-decoding. Throws only on a transport error / missing
    /// HTTP response — a non-2xx status is returned to the caller to interpret
    /// (used by the resumable upload, where 308 is a normal, non-terminal reply and
    /// a 2xx body may be empty/non-JSON). Mirrors `send`'s semaphore-bridged transport.
    private func sendRaw(_ req: URLRequest) throws -> (Data, HTTPURLResponse) {
        let semaphore = DispatchSemaphore(value: 0)
        let box = SyncResultBox<(Data, HTTPURLResponse)>()
        let task = session.dataTask(with: req) { data, response, error in
            if let error { box.result = .failure(APIError.transport(error.localizedDescription)) }
            else if let http = response as? HTTPURLResponse {
                box.result = .success((data ?? Data(), http))
            } else {
                box.result = .failure(APIError.transport("no HTTP response"))
            }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        return try box.result!.get()
    }

    private func send(_ req: URLRequest) throws -> Any {
        let semaphore = DispatchSemaphore(value: 0)
        // A reference box so the URLSession completion handler can hand its result
        // back without Swift 6's "mutation of captured var in concurrently-executing
        // code" diagnostic — the semaphore orders the single write strictly before
        // the read, so the access is safe.
        let box = SyncResultBox<(Data, HTTPURLResponse)>()
        let task = session.dataTask(with: req) { data, response, error in
            if let error { box.result = .failure(APIError.transport(error.localizedDescription)) }
            else if let http = response as? HTTPURLResponse {
                box.result = .success((data ?? Data(), http))
            } else {
                box.result = .failure(APIError.transport("no HTTP response"))
            }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        switch box.result! {
        case .failure(let e): throw e
        case .success(let (data, http)):
            guard (200..<300).contains(http.statusCode) else {
                throw APIError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
            }
            if data.isEmpty { return [:] }
            do { return try JSONSerialization.jsonObject(with: data) }
            catch { throw APIError.decoding(error.localizedDescription) }
        }
    }

    // ---- Decoding helpers ---------------------------------------------------

    private func decodeApp(_ o: [String: Any]) -> AppRecord {
        AppRecord(
            id: str(o["id"]) ?? "",
            workspaceId: str(o["workspace_id"]) ?? "",
            name: str(o["name"]) ?? "",
            bundleId: str(o["bundle_id"]) ?? "",
            platform: str(o["platform"]) ?? "ios"
        )
    }

    private func decodeFingerprint(_ json: Any) throws -> FingerprintRecord {
        guard let o = json as? [String: Any] else { throw APIError.decoding("fingerprint not an object") }
        return FingerprintRecord(
            id: str(o["id"]) ?? "",
            appId: str(o["app_id"]) ?? "",
            fingerprint: str(o["fingerprint"]) ?? "",
            isActive: (o["is_active"] as? Bool) ?? false,
            appVersion: str(o["app_version"]),
            components: Self.decodeStoredComponents(o["components"])
        )
    }

    /// Parse the backend's stored `components` JSON into `StoredFingerprintComponents`.
    /// Tolerant: any missing field becomes nil and the diff degrades gracefully.
    private static func decodeStoredComponents(_ raw: Any?) -> StoredFingerprintComponents? {
        guard let c = raw as? [String: Any], !c.isEmpty else { return nil }
        let hashes = (c["componentHashes"] as? [String: Any])?.compactMapValues { $0 as? String }
        return StoredFingerprintComponents(
            sdkVersion: c["sdkVersion"] as? String,
            wasmKitVersion: c["wasmKitVersion"] as? String,
            bridgeDefinitions: c["bridgeDefinitions"] as? [String],
            linkedFrameworks: c["linkedFrameworks"] as? [String],
            deploymentTarget: c["deploymentTarget"] as? String,
            swiftCompilerVersion: c["swiftCompilerVersion"] as? String,
            nativeSwiftFileCount: c["nativeSwiftFileCount"] as? Int,
            nativeGeneratedStubCount: c["nativeGeneratedStubCount"] as? Int,
            componentHashes: hashes,
            nativeSwiftFiles: c["nativeSwiftFiles"] as? [String],
            nativeGeneratedStubs: c["nativeGeneratedStubs"] as? [String]
        )
    }

    private func decodeEntitlements(_ json: Any) throws -> Entitlements {
        guard let o = json as? [String: Any] else {
            throw APIError.decoding("entitlements not an object")
        }
        return Entitlements(
            plan: str(o["plan"]) ?? "hobby",
            isPaid: (o["is_paid"] as? Bool) ?? false,
            canAbTest: (o["can_ab_test"] as? Bool) ?? false,
            canUseChannels: (o["can_use_channels"] as? Bool) ?? false,
            upgradeURL: str(o["upgrade_url"]) ?? "",
            upgradeAbMsg: str(o["upgrade_ab_msg"]) ?? "",
            upgradeChannelMsg: str(o["upgrade_channel_msg"]) ?? ""
        )
    }

    private func decodeModule(_ json: Any) throws -> ModuleRecord {
        guard let o = json as? [String: Any] else { throw APIError.decoding("module not an object") }
        return ModuleRecord(
            id: str(o["id"]) ?? "",
            appId: str(o["app_id"]) ?? "",
            version: str(o["version"]) ?? "",
            channel: str(o["channel"]) ?? "production",
            sha256: str(o["sha256"]) ?? "",
            sizeBytes: int(o["size_bytes"]) ?? 0,
            rolloutPct: int(o["rollout_pct"]) ?? 0,
            mandatory: (o["mandatory"] as? Bool) ?? false,
            isActive: (o["is_active"] as? Bool) ?? false,
            releaseNotes: str(o["release_notes"]),
            modulePath: str(o["module_gcs_path"]) ?? "",
            pushedAt: str(o["pushed_at"]) ?? "",
            rolledBackAt: str(o["rolled_back_at"]),
            minAppVersion: str(o["min_app_version"]),
            maxAppVersion: str(o["max_app_version"]),
            minOsVersion: str(o["min_os_version"]),
            targetCohort: str(o["target_cohort"])
        )
    }

    private func str(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        return nil
    }
    private func int(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let n = v as? NSNumber { return n.intValue }
        return nil
    }
}
