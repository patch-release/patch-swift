// SPDX-License-Identifier: Apache-2.0

import Foundation
import ArgumentParser
import Compiler

/// `Patch channels` — list the deployment channels seen for the configured app,
/// with the active module per channel.
///
/// Calls `GET /api/v1/apps/{app_id}/channels` (Wave-4 spec §3). The Compiler
/// `HTTPPatchAPI` has no `channels` method (it is owned by another track and
/// reused read-only here), so this command issues the GET directly with the
/// same `X-API-Key` auth + base-URL resolution. If the endpoint isn't deployed
/// yet (404 / not-found), it degrades gracefully by falling back to the distinct
/// channels visible via `GET /modules` (which the API client DOES expose).
struct Channels: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "channels",
        abstract: "List deployment channels for the configured app (+ active module per channel)."
    )

    @Option(name: .long, help: "Backend base URL override.")
    var baseURL: String?

    @Flag(name: .long, help: "Output JSON.")
    var json: Bool = false

    func run() throws {
        let (config, _) = try CLISupport.loadConfig()
        let appId = try CLISupport.requireAppID(config)
        let base = CLISupport.resolveBaseURL(baseURL, config: config)
        guard let key = CLISupport.resolveAPIKey(config: config) else {
            throw ValidationError(
                "No API key found. Set the PATCH_API_KEY env var, or `api_key:` / `app_key:` in .Patch.yml.")
        }

        // Preferred: the dedicated channels endpoint.
        if let rows = Spinner.run("Fetching channels", {
            try? fetchChannels(base: base, apiKey: key, appId: appId)
        }) {
            emit(rows, source: "GET /apps/\(appId)/channels")
            return
        }

        // Graceful degradation: derive channels from the module list.
        let api = try CLISupport.makeAPI(config: config, baseURLOverride: baseURL)
        let modules = try Spinner.run("Fetching modules") {
            try api.listModules(appId: appId, channel: nil)
        }
        var byChannel: [String: ChannelRow] = [:]
        for m in modules {
            // Keep the active module per channel; else the first seen.
            if byChannel[m.channel] == nil || m.isActive {
                byChannel[m.channel] = ChannelRow(
                    channel: m.channel,
                    activeVersion: m.isActive ? m.version : (byChannel[m.channel]?.activeVersion),
                    rolloutPct: m.isActive ? m.rolloutPct : (byChannel[m.channel]?.rolloutPct),
                    mandatory: m.isActive ? m.mandatory : (byChannel[m.channel]?.mandatory),
                    updatedAt: m.pushedAt
                )
            }
        }
        let rows = byChannel.values.sorted { $0.channel < $1.channel }
        emit(Array(rows), source: "derived from GET /modules (channels endpoint unavailable)")
    }

    // MARK: - Output

    private func emit(_ rows: [ChannelRow], source: String) {
        if json {
            let arr = rows.map { row -> [String: Any] in
                var o: [String: Any] = ["channel": row.channel]
                if let v = row.activeVersion { o["active_version"] = v }
                if let r = row.rolloutPct { o["rollout_pct"] = r }
                if let m = row.mandatory { o["mandatory"] = m }
                if let u = row.updatedAt { o["updated_at"] = u }
                return o
            }
            if let data = try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted, .sortedKeys]),
               let s = String(data: data, encoding: .utf8) {
                print(s)
            }
            return
        }

        print("Patch channels")
        print("==============")
        print("(\(source))")
        if rows.isEmpty {
            print("No channels found for this app yet. Release a module with `patchcli release --channel <name>`.")
            return
        }
        for row in rows {
            let v = row.activeVersion ?? "—"
            let r = row.rolloutPct.map { "\($0)%" } ?? "—"
            let m = (row.mandatory ?? false) ? " (mandatory)" : ""
            print("  \(row.channel.padding(toLength: 16, withPad: " ", startingAt: 0)) active=\(v)  rollout=\(r)\(m)")
        }
    }

    // MARK: - Direct GET /apps/{app_id}/channels

    struct ChannelRow {
        var channel: String
        var activeVersion: String?
        var rolloutPct: Int?
        var mandatory: Bool?
        var updatedAt: String?
    }

    /// Returns nil-throwing when the endpoint is missing so the caller can fall back.
    private func fetchChannels(base: String, apiKey: String, appId: String) throws -> [ChannelRow] {
        guard let rawBase = URL(string: base) else {
            throw ValidationError("Invalid backend base URL: \(base)")
        }
        // Normalize so a base that already ends in `/api/v1` (the canonical
        // production URL / SDK default) isn't doubled to `/api/v1/api/v1/...`.
        let url = HTTPPatchAPI.normalizedBase(rawBase)
            .appendingPathComponent("api/v1")
            .appendingPathComponent("apps")
            .appendingPathComponent(appId)
            .appendingPathComponent("channels")

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 30
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")

        let semaphore = DispatchSemaphore(value: 0)
        // Reference box (see Compiler.SyncResultBox) — avoids Swift 6's "mutation of
        // captured var" diagnostic; the semaphore orders the write before the read.
        let box = SyncResultBox<(Data, HTTPURLResponse)>()
        let task = URLSession.shared.dataTask(with: req) { data, response, error in
            if let error {
                box.result = .failure(APIError.transport(error.localizedDescription))
            } else if let http = response as? HTTPURLResponse {
                box.result = .success((data ?? Data(), http))
            } else {
                box.result = .failure(APIError.transport("no HTTP response"))
            }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        let (data, http): (Data, HTTPURLResponse)
        switch box.result! {
        case .failure(let e): throw e
        case .success(let pair): (data, http) = pair
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        let json = try JSONSerialization.jsonObject(with: data)
        guard let arr = json as? [[String: Any]] else {
            throw APIError.decoding("expected a JSON array of channels")
        }
        return arr.map { o in
            ChannelRow(
                channel: (o["channel"] as? String) ?? "",
                activeVersion: o["active_version"] as? String,
                rolloutPct: (o["rollout_pct"] as? NSNumber)?.intValue ?? (o["rollout_pct"] as? Int),
                mandatory: o["mandatory"] as? Bool,
                updatedAt: o["updated_at"] as? String
            )
        }
    }
}
