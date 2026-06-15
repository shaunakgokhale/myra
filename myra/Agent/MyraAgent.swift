import Foundation
import Observation
import UserNotifications
import FoundationModels

/// Which brain produces Myra's messages. Stored in UserDefaults and mirrored to
/// the server so the scheduler knows how to behave. Defaults to `.backendClaude`
/// so nothing changes until the user opts in.
enum AgentEngine: String {
    case backendClaude
    case shadow
    case onDeviceApple

    static var current: AgentEngine {
        AgentEngine(rawValue: UserDefaults.standard.string(forKey: "agentEngine") ?? "") ?? .backendClaude
    }
}

/// Tracks which task the session is performing so the DynamicProfile can route
/// to the right model. Light tasks run fully on-device; heavy tasks use Private
/// Cloud Compute with deep reasoning.
@Observable
final class MyraOrchestrator {
    enum Task { case light, heavy }
    var task: Task = .heavy
    var systemPrompt: String = ""

    let onDevice = SystemLanguageModel.default
    let pcc = PrivateCloudComputeLanguageModel()
}

/// The shared persona + full tool set. Bundling instructions and tools in one
/// DynamicInstructions lets both profiles reuse them without duplication.
struct MyraExpert: DynamicInstructions {
    let systemPrompt: String

    var body: some DynamicInstructions {
        Instructions(systemPrompt)
        QueryMetricsTool()
        RunCorrelationsTool()
        GetSleepAnalysisTool()
        GetCalendarTool()
        RememberTool()
        SchedulePushTool()
        SetShieldPolicyTool()
        ProposeCalendarBlockTool()
        ProposeExperimentTool()
        EvaluateExperimentTool()
    }
}

/// Swaps the backing model per task while keeping one continuous transcript:
/// on-device for light work, Private Cloud Compute (32K context, deep reasoning)
/// for the heavy multi-tool jobs.
struct MyraProfile: LanguageModelSession.DynamicProfile {
    let orchestrator: MyraOrchestrator

    var body: some DynamicProfile {
        switch orchestrator.task {
        case .light:
            Profile { MyraExpert(systemPrompt: orchestrator.systemPrompt) }
                .model(orchestrator.onDevice)
        case .heavy:
            Profile { MyraExpert(systemPrompt: orchestrator.systemPrompt) }
                .model(orchestrator.pcc)
                .reasoningLevel(.deep)
        }
    }
}

/// On-device counterpart to the server's `agent.ts`. Same persona, same prompts,
/// same tools — but the LLM + tool loop runs on the phone via Apple Foundation
/// Models. Tools call back to the server so every statistic and DB write stays
/// exactly where it was.
final class MyraAgent {
    static let shared = MyraAgent()

    /// True only when Apple Intelligence is enabled and the model is ready.
    static var isAvailable: Bool {
        switch SystemLanguageModel.default.availability {
        case .available: return true
        default: return false
        }
    }

    // Persistent session for the interactive Coach so the transcript carries
    // across turns while the app is alive.
    private var chatOrchestrator: MyraOrchestrator?
    private var chatSession: LanguageModelSession?

    // MARK: - Entry points (mirror agent.ts)

    func morningBriefing() async throws -> String {
        try await generate(task: .heavy, prompt: Prompts.morningBriefing)
    }

    func eveningWinddown() async throws -> String {
        try await generate(task: .light, prompt: Prompts.eveningWinddown)
    }

    func weeklyReport() async throws -> String {
        try await generate(task: .heavy, prompt: Prompts.weeklyReport)
    }

    func chat(_ text: String) async throws -> String {
        let ctx = try await APIClient.shared.agentContext()
        if chatSession == nil {
            let o = MyraOrchestrator()
            o.task = .light
            o.systemPrompt = ctx.systemPrompt
            chatOrchestrator = o
            chatSession = LanguageModelSession(profile: MyraProfile(orchestrator: o))
        } else {
            chatOrchestrator?.systemPrompt = ctx.systemPrompt
            chatOrchestrator?.task = .light
        }
        try? await APIClient.shared.uploadAgentMessage(kind: "chat_user", content: text, model: "user")
        let reply = try await chatSession!.respond(to: text).content
        try? await APIClient.shared.uploadAgentMessage(kind: "chat_assistant", content: reply, model: "apple-ondevice")
        return reply
    }

    // MARK: - Scheduled jobs (driven by the silent push wake)

    /// Generates a scheduled job on-device, then either (shadow) stores it for
    /// side-by-side comparison without disturbing the user, or (onDeviceApple)
    /// uploads it, posts the user notification, and tells the server it was
    /// delivered so the Claude fallback stands down.
    func handleScheduledJob(kind: String, engine: AgentEngine) async throws {
        let text: String
        let title: String
        let body: String
        let model: String

        switch kind {
        case "briefing":
            text = try await morningBriefing()
            title = "Morning briefing"
            body = Self.firstSentences(text, 180)
            model = "apple-pcc"
        case "winddown":
            text = try await eveningWinddown()
            title = "Wind-down"
            body = Self.firstSentences(text, 180)
            model = "apple-ondevice"
        case "weekly":
            text = try await weeklyReport()
            title = "Weekly life report"
            body = "Your week, analyzed. Open Myra to read it."
            model = "apple-pcc"
        default:
            return
        }

        if engine == .shadow {
            // Server already delivered the Claude version; keep this only for the
            // Lab comparison so the user-facing experience is untouched.
            try await APIClient.shared.uploadAgentMessage(kind: "\(kind)_shadow", content: text, model: model)
        } else {
            try await APIClient.shared.uploadAgentMessage(kind: kind, content: text, model: model)
            try await APIClient.shared.markJobComplete(kind: kind)
            await Self.postLocalNotification(title: title, body: body, category: kind.uppercased())
        }
    }

    // MARK: - Internals

    private func generate(task: MyraOrchestrator.Task, prompt: String) async throws -> String {
        let ctx = try await APIClient.shared.agentContext()
        let orchestrator = MyraOrchestrator()
        orchestrator.task = task
        orchestrator.systemPrompt = ctx.systemPrompt
        let session = LanguageModelSession(profile: MyraProfile(orchestrator: orchestrator))
        return try await session.respond(to: prompt).content
    }

    private static func postLocalNotification(title: String, body: String, category: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = category
        content.userInfo = ["kind": category.lowercased()]
        let req = UNNotificationRequest(
            identifier: "\(category)-\(Date.now.timeIntervalSince1970)",
            content: content,
            trigger: nil,
        )
        try? await UNUserNotificationCenter.current().add(req)
    }

    /// Mirrors the server's `firstSentences` truncation for notification bodies.
    static func firstSentences(_ text: String, _ maxLen: Int) -> String {
        if text.count <= maxLen { return text }
        let end = text.index(text.startIndex, offsetBy: maxLen - 1)
        var slice = String(text[..<end])
        if let lastSpace = slice.range(of: "\\s+\\S*$", options: .regularExpression) {
            slice.replaceSubrange(lastSpace, with: "")
        }
        return slice + "\u{2026}"
    }
}

/// Job prompts copied verbatim from the server's agent.ts so on-device output
/// matches the Claude pipeline.
private enum Prompts {
    static let morningBriefing = """
    Generate my morning briefing, led by my active quest. Steps:
    1. If I have an active quest, OPEN with it: today's task in one imperative line, plus where I am (e.g. "day 4 of 14"). If I have no active quest, open with one line nudging me to pick a recommended quest.
    2. Pull recent sleep + readiness (query_metrics over ~14 days) and get_sleep_analysis for a single grounding data point relevant to the quest. The latest Oura row is from this morning's publish (covering last night / "today's" readiness) — use it as current; do not say today's data is missing.
    3. Get today's calendar and note anything that threatens today's quest task.
    4. ONE concrete tip to succeed at the quest today.
    5. Honor the quest's assist: if assist is 'bedtime', schedule_push a bedtime nudge for tonight at (optimal bedtime - 45 min); if assist is 'shield', set_shield_policy for tonight (scale strictness to sleep debt). Otherwise only act if clearly warranted.
    Keep it under 110 words, quest-first. Plain text, no markdown headers.
    """

    static let eveningWinddown = """
    Generate my evening wind-down message (sent ~21:00). Look at today's activity, stress minutes, screen time so far, and tomorrow's first calendar event. Tell me: when to be in bed tonight and why (one data point), and one thing to avoid in the next 2 hours based on my discovered patterns. Under 60 words. Plain text.
    """

    static let weeklyReport = """
    Generate my weekly life report (Sunday evening). Steps:
    1. query_metrics for the key outcomes over 28 days; compare this week vs the previous three.
    2. run_correlations and surface the 2-3 strongest patterns in plain language.
    3. Review active experiments (evaluate_experiment if past end date) and report results honestly, including no-effects.
    4. remember anything newly learned.
    5. If there is no active experiment, propose_experiment for the most promising lever found.
    Structure: "This week", "Patterns", "Experiment", "Next week". Under 250 words.
    """
}
