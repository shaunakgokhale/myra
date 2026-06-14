import Foundation

/// Talks to the Myra backend on Railway.
final class APIClient: Sendable {
    static let shared = APIClient()

    private var baseURL: URL? {
        guard var s = UserDefaults.standard.string(forKey: "backendURL")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        // Tolerate common paste mistakes: missing scheme, trailing slashes,
        // or an accidental "/api" suffix (every route already starts with "api/").
        if !s.lowercased().hasPrefix("http") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        if s.lowercased().hasSuffix("/api") { s.removeLast(4) }
        return URL(string: s)
    }

    private var appToken: String {
        UserDefaults.standard.string(forKey: "appToken") ?? ""
    }

    var isConfigured: Bool { baseURL != nil }

    enum APIError: LocalizedError {
        case notConfigured
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Set the backend URL in Settings first."
            case .http(let code, let body): return "Server error \(code): \(body.prefix(200))"
            }
        }
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        guard let baseURL else { throw APIError.notConfigured }
        // Split an optional query string off the path: `appendingPathComponent`
        // percent-encodes "?", which would turn `api/dashboard?days=60` into
        // `api/dashboard%3Fdays=60` and 404 on the backend.
        let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var url = baseURL.appendingPathComponent(String(parts[0]))
        if parts.count > 1, var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            comps.percentEncodedQuery = String(parts[1])
            if let withQuery = comps.url { url = withQuery }
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 90
        req.setValue(appToken, forHTTPHeaderField: "x-app-token")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw APIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private func json<T: Decodable>(_ type: T.Type, path: String, method: String = "GET", body: Data? = nil) async throws -> T {
        let data = try await request(path, method: method, body: body)
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Endpoints

    func status() async throws -> BackendStatus {
        try await json(BackendStatus.self, path: "api/status")
    }

    func dashboard(days: Int = 60) async throws -> Dashboard {
        let data = try await request("api/dashboard?days=\(days)")
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return Dashboard() }

        var dash = Dashboard()
        if let rows = obj["days"] as? [[String: Any]] {
            dash.days = rows.compactMap { row in
                guard let day = row["day"] as? String else { return nil }
                var values: [String: Double] = [:]
                for (k, v) in row where k != "day" {
                    if let d = v as? Double { values[k] = d }
                    else if let i = v as? Int { values[k] = Double(i) }
                }
                return DayMetrics(day: day, values: values)
            }.sorted { $0.day < $1.day }
        }
        let dec = JSONDecoder()
        if let sd = obj["sleepDebt"], !(sd is NSNull),
           let d = try? JSONSerialization.data(withJSONObject: sd) {
            dash.sleepDebt = try? dec.decode(SleepDebt.self, from: d)
        }
        if let ob = obj["optimalBedtime"], !(ob is NSNull),
           let d = try? JSONSerialization.data(withJSONObject: ob) {
            dash.optimalBedtime = try? dec.decode(OptimalBedtime.self, from: d)
        }
        if let lm = obj["latestMessage"], !(lm is NSNull),
           let d = try? JSONSerialization.data(withJSONObject: lm) {
            dash.latestMessage = try? dec.decode(LatestMessage.self, from: d)
        }
        if let dir = obj["directives"] as? [String: Any] {
            if let sp = dir["shield_policy"],
               let d = try? JSONSerialization.data(withJSONObject: sp) {
                dash.shieldPolicy = try? dec.decode(ShieldPolicy.self, from: d)
            }
            if let cb = dir["calendar_block"],
               let d = try? JSONSerialization.data(withJSONObject: cb) {
                dash.calendarBlock = try? dec.decode(CalendarBlockProposal.self, from: d)
            }
        }
        return dash
    }

    func insights() async throws -> Insights {
        try await json(Insights.self, path: "api/insights")
    }

    func messages() async throws -> [AgentMessage] {
        try await json([AgentMessage].self, path: "api/messages")
    }

    func chatHistory() async throws -> [AgentMessage] {
        try await json([AgentMessage].self, path: "api/chat/history")
    }

    func sendChat(_ message: String) async throws -> String {
        struct Reply: Codable { let reply: String }
        let body = try JSONEncoder().encode(["message": message])
        return try await json(Reply.self, path: "api/chat", method: "POST", body: body).reply
    }

    func experiments() async throws -> [Experiment] {
        try await json([Experiment].self, path: "api/experiments")
    }

    func logExperiment(id: Int, complied: Bool) async throws {
        struct Log: Codable { let complied: Bool }
        let body = try JSONEncoder().encode(Log(complied: complied))
        _ = try await request("api/experiments/\(id)/log", method: "POST", body: body)
    }

    func registerDevice(token: String) async throws {
        let body = try JSONEncoder().encode(["token": token])
        _ = try await request("api/devices", method: "POST", body: body)
    }

    struct DailyMetricUpload: Codable {
        let day: String
        let source: String
        let metric: String
        let value: Double
    }

    func uploadDaily(_ metrics: [DailyMetricUpload]) async throws {
        guard !metrics.isEmpty else { return }
        let body = try JSONEncoder().encode(["metrics": metrics])
        _ = try await request("api/ingest/daily", method: "POST", body: body)
    }

    struct CalendarEventUpload: Codable {
        let id: String
        let title: String
        let start: String
        let end: String
        let allDay: Bool
    }

    func uploadCalendar(_ events: [CalendarEventUpload]) async throws {
        guard !events.isEmpty else { return }
        let body = try JSONEncoder().encode(["events": events])
        _ = try await request("api/ingest/calendar", method: "POST", body: body)
    }

    func directives() async throws -> ShieldPolicy? {
        let data = try await request("api/directives")
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sp = obj["shield_policy"],
              let d = try? JSONSerialization.data(withJSONObject: sp) else { return nil }
        return try? JSONDecoder().decode(ShieldPolicy.self, from: d)
    }

    func triggerBriefing() async throws -> String {
        struct R: Codable { let text: String }
        return try await json(R.self, path: "api/admin/briefing", method: "POST").text
    }

    // MARK: - On-device Apple Foundation Models bridge

    /// Everything needed to assemble the same system prompt the server builds.
    struct AgentContext: Codable {
        let systemPrompt: String
        let memory: String
        let experiments: String
        struct Clock: Codable {
            let dateStr: String
            let hour: Int
            let minute: Int
            let timezone: String
        }
        let clock: Clock
    }

    func agentContext() async throws -> AgentContext {
        try await json(AgentContext.self, path: "api/agent/context")
    }

    /// Invokes a server-side tool by name. The result is returned as a JSON
    /// string to hand straight back to the on-device model's next turn. All DB
    /// writes and statistics still happen in the same server code as before.
    func agentTool(name: String, input: [String: Any]) async throws -> String {
        let payload: [String: Any] = ["name": name, "input": input]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let data = try await request("api/agent/tool", method: "POST", body: body)
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let result = obj["result"] {
                if JSONSerialization.isValidJSONObject(result),
                   let rd = try? JSONSerialization.data(withJSONObject: result),
                   let s = String(data: rd, encoding: .utf8) {
                    return s
                }
                return String(describing: result)
            }
            if let err = obj["error"] { return "{\"error\":\"\(err)\"}" }
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Uploads a generated message. `model` tags the producer
    /// (apple-ondevice | apple-pcc | claude) for the dashboard + shadow eval.
    func uploadAgentMessage(kind: String, content: String, model: String) async throws {
        let payload: [String: Any] = ["kind": kind, "content": content, "meta": ["model": model]]
        let body = try JSONSerialization.data(withJSONObject: payload)
        _ = try await request("api/agent/messages", method: "POST", body: body)
    }

    /// Tells the server the on-device agent delivered a scheduled job, so the
    /// server-side Claude fallback stands down.
    func markJobComplete(kind: String) async throws {
        _ = try await request("api/agent/jobs/\(kind)/complete", method: "POST", body: Data("{}".utf8))
    }

    /// Reports the active engine so the scheduler knows whether to generate
    /// with Claude, run shadow, or defer to the on-device Apple agent.
    func setAgentEngine(_ engine: String) async throws {
        let body = try JSONEncoder().encode(["engine": engine])
        _ = try await request("api/agent/engine", method: "POST", body: body)
    }

    /// Messages of a specific kind (e.g. "briefing" vs "briefing_shadow").
    func messages(kind: String) async throws -> [AgentMessage] {
        try await json([AgentMessage].self, path: "api/messages?kind=\(kind)")
    }
}
