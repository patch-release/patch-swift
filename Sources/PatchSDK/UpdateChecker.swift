import Foundation

// MARK: - Wire protocol (matches backend/app/schemas/module.py + event.py EXACTLY)

/// Request body for `POST /api/v1/modules/check`.
///
/// Field names are the snake_case the backend's `UpdateCheckRequest` pydantic
/// model requires. `app_id` is a UUID string; `channel` defaults to
/// "production". (`current_version`, `fingerprint`, `device_id`, `app_id` are
/// required by the backend; the rest are optional.)
public struct UpdateCheckRequest: Codable, Equatable, Sendable {
    public var current_version: String
    public var fingerprint: String
    public var device_id: String
    public var app_id: String
    public var os_version: String?
    public var app_version: String?
    public var sdk_version: String?
    /// App-assigned cohort label (e.g. "beta", "internal"). When a release sets
    /// `target_cohort`, only devices reporting the matching cohort are served
    /// it. Nil when the app set no cohort; the backend then derives a stable
    /// hash-bucket cohort from `device_id` for percentage-style cohort
    /// targeting. Matches the backend `UpdateCheckRequest.cohort` field.
    public var cohort: String?
    public var channel: String

    public init(
        current_version: String,
        fingerprint: String,
        device_id: String,
        app_id: String,
        os_version: String? = nil,
        app_version: String? = nil,
        sdk_version: String? = nil,
        cohort: String? = nil,
        channel: String = "production"
    ) {
        self.current_version = current_version
        self.fingerprint = fingerprint
        self.device_id = device_id
        self.app_id = app_id
        self.os_version = os_version
        self.app_version = app_version
        self.sdk_version = sdk_version
        self.cohort = cohort
        self.channel = channel
    }
}

/// Response from `POST /api/v1/modules/check` — mirrors the backend
/// `UpdateCheckResponse`. All update fields are nil when `has_update == false`.
public struct UpdateCheckResponse: Codable, Equatable, Sendable {
    public var has_update: Bool
    public var version: String?
    public var module_url: String?
    public var diff_url: String?
    public var sha256: String?
    public var size: Int?
    public var diff_size: Int?
    public var mandatory: Bool
    public var release_notes: String?

    public init(
        has_update: Bool,
        version: String? = nil,
        module_url: String? = nil,
        diff_url: String? = nil,
        sha256: String? = nil,
        size: Int? = nil,
        diff_size: Int? = nil,
        mandatory: Bool = false,
        release_notes: String? = nil
    ) {
        self.has_update = has_update
        self.version = version
        self.module_url = module_url
        self.diff_url = diff_url
        self.sha256 = sha256
        self.size = size
        self.diff_size = diff_size
        self.mandatory = mandatory
        self.release_notes = release_notes
    }

    public enum CodingKeys: String, CodingKey {
        case has_update, version, module_url, diff_url, sha256, size, diff_size, mandatory, release_notes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        has_update = try c.decode(Bool.self, forKey: .has_update)
        version = try c.decodeIfPresent(String.self, forKey: .version)
        module_url = try c.decodeIfPresent(String.self, forKey: .module_url)
        diff_url = try c.decodeIfPresent(String.self, forKey: .diff_url)
        sha256 = try c.decodeIfPresent(String.self, forKey: .sha256)
        size = try c.decodeIfPresent(Int.self, forKey: .size)
        diff_size = try c.decodeIfPresent(Int.self, forKey: .diff_size)
        // backend defaults mandatory=false and may omit it; tolerate absence.
        mandatory = try c.decodeIfPresent(Bool.self, forKey: .mandatory) ?? false
        release_notes = try c.decodeIfPresent(String.self, forKey: .release_notes)
    }
}

/// Telemetry event for `POST /api/v1/events` — mirrors the backend `EventCreate`.
/// `event_type` is a free-form string in the schema; see `EventType` for the
/// vocabulary the backend stats endpoint aggregates on.
public struct DeviceEventPayload: Codable, Equatable, Sendable {
    public var app_id: String
    public var device_id: String
    public var event_type: String
    public var module_version: String?
    public var os_version: String?
    public var device_model: String?
    public var app_version: String?
    public var error_message: String?
    public var duration_ms: Int?

    public init(
        app_id: String,
        device_id: String,
        event_type: String,
        module_version: String? = nil,
        os_version: String? = nil,
        device_model: String? = nil,
        app_version: String? = nil,
        error_message: String? = nil,
        duration_ms: Int? = nil
    ) {
        self.app_id = app_id
        self.device_id = device_id
        self.event_type = event_type
        self.module_version = module_version
        self.os_version = os_version
        self.device_model = device_model
        self.app_version = app_version
        self.error_message = error_message
        self.duration_ms = duration_ms
    }
}

/// Telemetry event-type vocabulary.
///
/// NOTE / WIRE MISMATCH: the backend's `GET /modules/{id}/stats` aggregates on
/// the literal event types `"download"`, `"activation"`, and `"error"`
/// (`routes/modules.py`). The SDK therefore emits exactly those three strings so
/// stats populate. `fallback` is also emitted (extra signal the stats endpoint
/// ignores today but the raw rows capture). See README "Wire protocol notes".
public enum EventType: String, Sendable {
    case download
    case activation
    case error
    case fallback
}

// MARK: - HTTP transport (mockable; no real network in tests)

/// Minimal HTTP transport so tests can inject a mock `URLProtocol` or use
/// `file://` URLs without real network calls. The default uses `URLSession`.
public protocol HTTPTransport: Sendable {
    /// Perform `request`, returning the body bytes and HTTP status (or 200 for
    /// non-HTTP responses like `file://`).
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

/// `URLSession`-backed transport. Construct with a custom `URLSessionConfiguration`
/// (e.g. one whose `protocolClasses` includes a mock) to intercept requests.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
    public init(configuration: URLSessionConfiguration) {
        self.session = URLSession(configuration: configuration)
    }
    public func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        return (data, status)
    }
}

// MARK: - Exponential backoff

/// Exponential backoff with full jitter, capped. Pure value type so the schedule
/// is unit-testable without sleeping. Used by `UpdateChecker` after a failed poll.
public struct ExponentialBackoff: Sendable {
    public let base: TimeInterval
    public let multiplier: Double
    public let maxDelay: TimeInterval
    public let jitter: Bool
    private(set) public var attempt: Int = 0

    public init(
        base: TimeInterval = 2,
        multiplier: Double = 2,
        maxDelay: TimeInterval = 300,
        jitter: Bool = true
    ) {
        self.base = base
        self.multiplier = multiplier
        self.maxDelay = maxDelay
        self.jitter = jitter
    }

    /// The deterministic (un-jittered) delay for a given attempt number
    /// (attempt 0 → `base`, 1 → `base*mult`, …), capped at `maxDelay`.
    public func delay(forAttempt n: Int) -> TimeInterval {
        let raw = base * pow(multiplier, Double(max(0, n)))
        return min(raw, maxDelay)
    }

    /// Advance one failure and return the next delay (full-jittered if enabled).
    public mutating func nextDelay() -> TimeInterval {
        // `Double.random(in: 0...capped)` TRAPS the app (uncatchable crash) on the
        // first failed poll if `capped` is not a finite, non-negative value:
        //   * a misconfigured negative `base` → negative `capped` → "Range
        //     requires lowerBound <= upperBound";
        //   * `maxDelay: .infinity` (a legal arg) or a `base`/`multiplier` that
        //     overflows `pow` to `+Infinity` → "no uniform distribution on an
        //     infinite range".
        // Sanitize to a finite, non-negative delay so a back-off (which only runs
        // on the error path) can never itself crash the app.
        let raw = delay(forAttempt: attempt)
        let capped = raw.isFinite ? max(0, raw) : max(0, maxDelay.isFinite ? maxDelay : 0)
        attempt += 1
        guard jitter else { return capped }
        return Double.random(in: 0...capped)
    }

    /// Reset the backoff after a successful poll.
    public mutating func reset() { attempt = 0 }
}

// MARK: - UpdateChecker

/// Polls the backend for updates and fires telemetry. Network I/O is funneled
/// through an injectable `HTTPTransport`, so tests use a mock with no real
/// network. Holds an `ExponentialBackoff` that callers consult to schedule the
/// next poll after a failure.
public final class UpdateChecker: @unchecked Sendable {

    public enum CheckError: Error, CustomStringConvertible {
        case badURL(String)
        case httpStatus(Int)
        case decode(Error)
        case transport(Error)
        public var description: String {
            switch self {
            case .badURL(let s): return "update-check: bad URL \(s)"
            case .httpStatus(let c): return "update-check: HTTP \(c)"
            case .decode(let e): return "update-check: response decode failed: \(e)"
            case .transport(let e): return "update-check: transport error: \(e)"
            }
        }
    }

    private let baseURL: URL
    private let transport: HTTPTransport
    private let lock = NSLock()
    private var _backoff: ExponentialBackoff

    /// - Parameters:
    ///   - baseURL: API root, e.g. `https://api.patchrelease.com/api/v1`. The checker
    ///     appends `/modules/check` and `/events`.
    ///   - transport: HTTP transport (default `URLSession.shared`).
    ///   - backoff: backoff policy for failed polls.
    public init(
        baseURL: URL,
        transport: HTTPTransport = URLSessionTransport(),
        backoff: ExponentialBackoff = ExponentialBackoff()
    ) {
        self.baseURL = baseURL
        self.transport = transport
        self._backoff = backoff
    }

    /// The next delay to wait after the most recent failure. Advances the
    /// backoff; reset with `resetBackoff()` after success.
    public func nextBackoffDelay() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return _backoff.nextDelay()
    }

    public func resetBackoff() {
        lock.lock(); defer { lock.unlock() }
        _backoff.reset()
    }

    public var backoffAttempt: Int {
        lock.lock(); defer { lock.unlock() }
        return _backoff.attempt
    }

    /// Poll `POST /modules/check`. On success the backoff is reset; on failure
    /// the caller should consult `nextBackoffDelay()` to schedule a retry.
    public func check(_ request: UpdateCheckRequest) async throws -> UpdateCheckResponse {
        let url = baseURL.appendingPathComponent("modules/check")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(request)

        let data: Data
        let status: Int
        do {
            (data, status) = try await transport.send(req)
        } catch {
            throw CheckError.transport(error)
        }
        guard (200...299).contains(status) else { throw CheckError.httpStatus(status) }
        do {
            let decoded = try JSONDecoder().decode(UpdateCheckResponse.self, from: data)
            resetBackoff()
            return decoded
        } catch {
            throw CheckError.decode(error)
        }
    }

    /// Fire-and-forget telemetry to `POST /events`. Best-effort: failures are
    /// swallowed (telemetry must never break the app). Returns the HTTP status
    /// for testability.
    @discardableResult
    public func reportEvent(_ event: DeviceEventPayload) async -> Int? {
        let url = baseURL.appendingPathComponent("events")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let body = try? JSONEncoder().encode(event) else { return nil }
        req.httpBody = body
        return try? await transport.send(req).1
    }
}
