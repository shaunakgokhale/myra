import Foundation
import FoundationModels

// The on-device Apple Foundation Models agent's tools. Each one mirrors a tool
// in the server's `TOOLS` table verbatim (same name + description so model
// behavior matches), and routes the call to `POST /api/agent/tool`, which runs
// the exact same server implementation. No DB logic moves to the device.

struct QueryMetricsTool: Tool {
    let name = "query_metrics"
    let description = "Query the unified daily timeline. Returns rows of {day, metric, value} for the requested metrics over the last N days. Metric names include: sleep_score, readiness_score, activity_score, total_sleep_s, deep_sleep_s, rem_sleep_s, avg_hrv, lowest_hr_sleep, sleep_efficiency, sleep_latency_s, bedtime_start_min (minutes, 1380=23:00, 1500=01:00), steps, active_calories, sedentary_time_s, stress_high_s, temperature_deviation, spo2_avg, screen_total_min, screen_late_min, meeting_count, calendar_busy_s, first_event_min, mindful_min, caffeine_mg, alcohol_drinks, temp_max_c, daylight_s, plus workout_*/session_*/tag_* entries."

    @Generable
    struct Arguments {
        @Guide(description: "Metric names to fetch")
        var metrics: [String]
        @Guide(description: "How many days back (default 30)")
        var days: Int?
    }

    func call(arguments: Arguments) async throws -> String {
        var input: [String: Any] = ["metrics": arguments.metrics]
        if let days = arguments.days { input["days"] = days }
        return try await APIClient.shared.agentTool(name: name, input: input)
    }
}

struct RunCorrelationsTool: Tool {
    let name = "run_correlations"
    let description = "Run the statistical discovery engine: lagged Pearson correlations between behaviors/context and body outcomes over the last 120 days. Returns only statistically meaningful results (|r|>=0.3, p<0.05, n>=10). lag=0 means same day, lag=1 means the input affects the NEXT day's outcome."

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        try await APIClient.shared.agentTool(name: name, input: [:])
    }
}

struct GetSleepAnalysisTool: Tool {
    let name = "get_sleep_analysis"
    let description = "Get computed sleep debt (vs personal need) and the statistically optimal bedtime window."

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        try await APIClient.shared.agentTool(name: name, input: [:])
    }
}

struct GetCalendarTool: Tool {
    let name = "get_calendar"
    let description = "Get calendar events between now and N days ahead (default 2), including meeting load."

    @Generable
    struct Arguments {
        @Guide(description: "How many days ahead to look")
        var days_ahead: Int?
    }

    func call(arguments: Arguments) async throws -> String {
        var input: [String: Any] = [:]
        if let d = arguments.days_ahead { input["days_ahead"] = d }
        return try await APIClient.shared.agentTool(name: name, input: input)
    }
}

struct RememberTool: Tool {
    let name = "remember"
    let description = "Write a fact to long-term memory so future briefings/conversations know it. Use for discovered patterns, user preferences, what advice was followed or ignored, and outcomes of suggestions. Keep each memory one sentence."

    @Generable
    struct Arguments {
        @Guide(description: "One of: pattern, preference, outcome, observation")
        var category: String
        @Guide(description: "The fact to remember, one sentence")
        var content: String
        @Guide(description: "Importance 1-10")
        var importance: Int?
    }

    func call(arguments: Arguments) async throws -> String {
        var input: [String: Any] = ["category": arguments.category, "content": arguments.content]
        if let imp = arguments.importance { input["importance"] = imp }
        return try await APIClient.shared.agentTool(name: name, input: input)
    }
}

struct SchedulePushTool: Tool {
    let name = "schedule_push"
    let description = "Schedule a push notification to the user's phone at a specific time (ISO 8601 with timezone). Use sparingly and only when timing matters (bedtime nudge, pre-meeting recovery reminder)."

    @Generable
    struct Arguments {
        @Guide(description: "ISO 8601 timestamp with timezone")
        var send_at: String
        var title: String
        var body: String
    }

    func call(arguments: Arguments) async throws -> String {
        try await APIClient.shared.agentTool(name: name, input: [
            "send_at": arguments.send_at,
            "title": arguments.title,
            "body": arguments.body,
        ])
    }
}

struct SetShieldPolicyTool: Tool {
    let name = "set_shield_policy"
    let description = "Set tonight's Screen Time shield policy on the phone. strictness: 0=off, 1=gentle (shield from winddown time), 2=strict (shield earlier, stronger copy). Set winddown_time as HH:MM in the user's timezone. Scale strictness with sleep debt: debt > 5h => 2, debt 2-5h => 1, else 0-1."

    @Generable
    struct Arguments {
        @Guide(description: "0=off, 1=gentle, 2=strict")
        var strictness: Int
        @Guide(description: "Wind-down time as HH:MM in the user's timezone")
        var winddown_time: String
        var reason: String
    }

    func call(arguments: Arguments) async throws -> String {
        try await APIClient.shared.agentTool(name: name, input: [
            "strictness": arguments.strictness,
            "winddown_time": arguments.winddown_time,
            "reason": arguments.reason,
        ])
    }
}

struct ProposeCalendarBlockTool: Tool {
    let name = "propose_calendar_block"
    let description = "Propose a recovery or wind-down block to be written into the user's calendar (the phone writes it via EventKit on next sync). Use for recovery blocks on heavy days or wind-down blocks before the optimal bedtime."

    @Generable
    struct Arguments {
        @Guide(description: "e.g. 'Recovery block' or 'Wind-down'")
        var title: String
        @Guide(description: "ISO 8601 timestamp")
        var start: String
        var duration_minutes: Int
        var notes: String?
    }

    func call(arguments: Arguments) async throws -> String {
        var input: [String: Any] = [
            "title": arguments.title,
            "start": arguments.start,
            "duration_minutes": arguments.duration_minutes,
        ]
        if let n = arguments.notes { input["notes"] = n }
        return try await APIClient.shared.agentTool(name: name, input: input)
    }
}

struct ProposeExperimentTool: Tool {
    let name = "propose_experiment"
    let description = "Propose an n=1 experiment. Choose a clear intervention the user can comply with, a single target metric from the timeline, and a duration of 10-21 days. The baseline is the preceding period of equal length."

    @Generable
    struct Arguments {
        var hypothesis: String
        var intervention: String
        @Guide(description: "A single metric name from the timeline")
        var target_metric: String
        @Guide(description: "Duration in days (10-21)")
        var duration_days: Int
    }

    func call(arguments: Arguments) async throws -> String {
        try await APIClient.shared.agentTool(name: name, input: [
            "hypothesis": arguments.hypothesis,
            "intervention": arguments.intervention,
            "target_metric": arguments.target_metric,
            "duration_days": arguments.duration_days,
        ])
    }
}

struct EvaluateExperimentTool: Tool {
    let name = "evaluate_experiment"
    let description = "Evaluate a completed or running experiment by id: compares the target metric against baseline (Cohen's d)."

    @Generable
    struct Arguments {
        var experiment_id: Int
    }

    func call(arguments: Arguments) async throws -> String {
        try await APIClient.shared.agentTool(name: name, input: ["experiment_id": arguments.experiment_id])
    }
}
