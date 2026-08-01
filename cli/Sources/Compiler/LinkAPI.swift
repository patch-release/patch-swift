// SPDX-License-Identifier: Apache-2.0

import Foundation

// MARK: - CLI link sessions (the `patchcli init` browser hand-off)
//
// Mirrors the OAuth device flow. `patchcli init` creates a short-lived link
// session on the backend (unauthenticated — it carries only the detected bundle
// id + app name), opens the console's `/cli-connect?code=…` page in the
// developer's browser, and polls `GET /cli/link/{code}` with a CLI-held
// `poll_secret` until the signed-in developer confirms. The backend then
// delivers the app identity + `pak_…` key exactly once.

/// Returned by `POST /api/v1/cli/link`.
public struct CliLinkSession: Sendable, Equatable {
    public let code: String
    public let pollSecret: String
    public let connectURL: String
    public let expiresInSeconds: Int
    public let pollIntervalSeconds: Int

    public init(code: String, pollSecret: String, connectURL: String,
                expiresInSeconds: Int, pollIntervalSeconds: Int) {
        self.code = code; self.pollSecret = pollSecret; self.connectURL = connectURL
        self.expiresInSeconds = expiresInSeconds
        self.pollIntervalSeconds = pollIntervalSeconds
    }
}

/// One poll result from `GET /api/v1/cli/link/{code}`.
public enum CliLinkPollResult: Sendable, Equatable {
    case pending
    /// Confirmed in the console — the one-time app payload.
    case confirmed(app: LinkedApp, reusedExisting: Bool)
    /// The key was already delivered to an earlier poll (shouldn't happen in a
    /// single CLI run; surfaced so the loop can stop with a clear message).
    case consumed
    case expired

    public struct LinkedApp: Sendable, Equatable {
        public let id: String
        public let workspaceId: String
        public let name: String
        public let bundleId: String
        /// PUBLIC device identifier — baked into `Patch.configure(appKey:)`, so it
        /// ships inside the app binary. It authorizes nothing.
        public let appKey: String
        /// SECRET publish credential (`ppt_…`) — authorizes push/release. Written
        /// to `.Patch.yml`, NEVER into app source. Optional so the CLI still
        /// works against a backend that predates the credential split (it then
        /// reports the missing token rather than failing to decode).
        public let publishToken: String?

        public init(id: String, workspaceId: String, name: String,
                    bundleId: String, appKey: String, publishToken: String? = nil) {
            self.id = id; self.workspaceId = workspaceId; self.name = name
            self.bundleId = bundleId; self.appKey = appKey
            self.publishToken = publishToken
        }
    }
}

/// Injectable so the init flow's poll loop is unit-testable without a backend.
public protocol CliLinkAPI: Sendable {
    func createLink(bundleId: String, name: String, platform: String) throws -> CliLinkSession
    func poll(code: String, secret: String) throws -> CliLinkPollResult
}

/// Real HTTP client. Unauthenticated by design (the whole point of the flow is
/// that the CLI has no credentials yet); the `poll_secret` is the credential.
public struct HTTPCliLinkAPI: CliLinkAPI {
    public let baseURL: URL
    public let session: URLSession
    public let timeout: TimeInterval

    public init(baseURL: URL, session: URLSession = .shared, timeout: TimeInterval = 15) {
        self.baseURL = baseURL
        self.session = session
        self.timeout = timeout
    }

    private func apiURL(_ path: String) -> URL {
        HTTPPatchAPI.normalizedBase(baseURL)
            .appendingPathComponent("api/v1").appendingPathComponent(path)
    }

    public func createLink(bundleId: String, name: String, platform: String) throws -> CliLinkSession {
        var req = URLRequest(url: apiURL("cli/link"))
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "bundle_id": bundleId, "name": name, "platform": platform,
        ])
        let json = try send(req)
        guard let o = json as? [String: Any],
              let code = o["code"] as? String,
              let secret = o["poll_secret"] as? String,
              let url = o["connect_url"] as? String else {
            throw APIError.decoding("unexpected /cli/link response shape")
        }
        return CliLinkSession(
            code: code,
            pollSecret: secret,
            connectURL: url,
            expiresInSeconds: (o["expires_in_seconds"] as? Int) ?? 900,
            pollIntervalSeconds: (o["poll_interval_seconds"] as? Int) ?? 2
        )
    }

    public func poll(code: String, secret: String) throws -> CliLinkPollResult {
        var comps = URLComponents(url: apiURL("cli/link/\(code)"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "secret", value: secret)]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        let json = try send(req)
        guard let o = json as? [String: Any], let status = o["status"] as? String else {
            throw APIError.decoding("unexpected /cli/link poll response shape")
        }
        switch status {
        case "pending": return .pending
        case "consumed": return .consumed
        case "expired": return .expired
        case "confirmed":
            guard let app = o["app"] as? [String: Any],
                  let id = app["id"] as? String,
                  let ws = app["workspace_id"] as? String,
                  let key = app["app_key"] as? String, !key.isEmpty else {
                throw APIError.decoding("confirmed link poll carried no app payload")
            }
            return .confirmed(
                app: CliLinkPollResult.LinkedApp(
                    id: id,
                    workspaceId: ws,
                    name: (app["name"] as? String) ?? "",
                    bundleId: (app["bundle_id"] as? String) ?? "",
                    appKey: key,
                    publishToken: (app["publish_token"] as? String).flatMap {
                        $0.isEmpty ? nil : $0
                    }
                ),
                reusedExisting: (o["reused_existing"] as? Bool) ?? false
            )
        default:
            throw APIError.decoding("unknown link status `\(status)`")
        }
    }

    // Same synchronous transport pattern as HTTPPatchAPI (one-shot CLI).
    private func send(_ req: URLRequest) throws -> Any {
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
}

/// Pure poll-loop decision logic, separated from sleeping/IO so it is testable:
/// given a sequence of poll outcomes, the loop's terminal state.
public enum CliLinkWait {
    public enum Outcome: Sendable, Equatable {
        case linked(CliLinkPollResult.LinkedApp, reusedExisting: Bool)
        case expired
        case consumed
        /// Polling errored more times in a row than the tolerance allows.
        case failed(message: String)
        case timedOut
    }

    /// How many consecutive transport errors to tolerate before giving up.
    /// Transient blips (laptop Wi-Fi, backend deploy) shouldn't abort a flow
    /// that is otherwise seconds from succeeding.
    public static let errorTolerance = 5

    /// Drive `poll` until a terminal outcome, sleeping `interval` between
    /// attempts via `sleeper` (injectable for tests) and giving up at `deadline`.
    public static func wait(
        api: CliLinkAPI,
        session: CliLinkSession,
        now: @escaping () -> Date = Date.init,
        sleeper: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        onPoll: (Int) -> Void = { _ in }
    ) -> Outcome {
        let deadline = now().addingTimeInterval(TimeInterval(session.expiresInSeconds))
        let interval = TimeInterval(max(1, session.pollIntervalSeconds))
        var consecutiveErrors = 0
        var attempt = 0
        while now() < deadline {
            attempt += 1
            onPoll(attempt)
            do {
                switch try api.poll(code: session.code, secret: session.pollSecret) {
                case .pending:
                    consecutiveErrors = 0
                case .confirmed(let app, let reused):
                    return .linked(app, reusedExisting: reused)
                case .consumed:
                    return .consumed
                case .expired:
                    return .expired
                }
            } catch {
                consecutiveErrors += 1
                if consecutiveErrors >= errorTolerance {
                    return .failed(message: "\(error)")
                }
            }
            sleeper(interval)
        }
        return .timedOut
    }
}
