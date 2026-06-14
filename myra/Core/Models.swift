import Foundation

// A day row is a dynamic bag of metric -> value.
struct DayMetrics: Identifiable {
    let day: String
    let values: [String: Double]
    var id: String { day }

    var date: Date {
        ISO8601DateFormatter.dayFormatter.date(from: day + "T12:00:00Z") ?? .now
    }

    subscript(_ metric: String) -> Double? { values[metric] }
}

extension ISO8601DateFormatter {
    static let dayFormatter = ISO8601DateFormatter()
}

struct SleepDebt: Codable {
    let debtHours: Double
    let personalNeedHours: Double
    let last7AvgHours: Double
}

struct OptimalBedtime: Codable {
    let bestBedtimeMin: Double
    let bestBedtimeLabel: String
    let avgScoreInWindow: Double
    let sampleSize: Int
}

struct AgentMessage: Codable, Identifiable {
    let id: Int
    let kind: String
    let content: String
    let created_at: String
}

struct LatestMessage: Codable {
    let content: String
    let created_at: String
}

struct ShieldPolicy: Codable {
    let strictness: Int
    let winddownTime: String // "HH:MM"
    let reason: String?
}

struct CalendarBlockProposal: Codable {
    let title: String
    let start: String       // ISO timestamp
    let durationMinutes: Int
    let notes: String?
    let proposedAt: String
}

struct Dashboard {
    var days: [DayMetrics] = []
    var sleepDebt: SleepDebt?
    var optimalBedtime: OptimalBedtime?
    var latestMessage: LatestMessage?
    var shieldPolicy: ShieldPolicy?
    var calendarBlock: CalendarBlockProposal?

    var today: DayMetrics? { days.last }

    /// Most recent day that actually carries Oura scores — the latest calendar
    /// row is often the current day with only partial (weather/HealthKit) data.
    var lastScored: DayMetrics? {
        days.last { $0["readiness_score"] != nil || $0["sleep_score"] != nil || $0["activity_score"] != nil }
            ?? days.last
    }

    /// Most recent night with sleep data.
    var lastNight: DayMetrics? {
        days.last { $0["total_sleep_s"] != nil }
    }

    /// The most recent non-nil value for a metric across the loaded days.
    func latest(_ metric: String) -> Double? {
        days.last { $0[metric] != nil }?[metric]
    }

    func series(_ metric: String, last n: Int = 30) -> [(date: Date, value: Double)] {
        days.suffix(n).compactMap { row in
            guard let v = row[metric] else { return nil }
            return (row.date, v)
        }
    }

    func median(_ metric: String, last n: Int = 30) -> Double? {
        let vals = days.suffix(n).compactMap { $0[metric] }.sorted()
        guard !vals.isEmpty else { return nil }
        return vals[vals.count / 2]
    }
}

struct Correlation: Codable, Identifiable {
    let x: String
    let y: String
    let lag: Int
    let n: Int
    let r: Double
    let p: Double
    var id: String { "\(x)-\(y)-\(lag)" }
}

struct Insights: Codable {
    let correlations: [Correlation]
    let sleepDebt: SleepDebt?
    let optimalBedtime: OptimalBedtime?
}

struct Experiment: Codable, Identifiable {
    let id: Int
    let hypothesis: String
    let intervention: String
    let target_metric: String
    let start_day: String
    let end_day: String
    let status: String
    let result: ExperimentResult?
}

struct ExperimentResult: Codable {
    let baselineMean: Double?
    let experimentMean: Double?
    let deltaPct: Double?
    let cohensD: Double?
    let verdict: String?
    let complianceRate: Double?
}

struct BackendStatus: Codable {
    let ouraConnected: Bool
    let backfillDone: Bool
    let latestOuraDay: String?
    let agentConfigured: Bool
    let oauthStartUrl: String
}

enum MetricNames {
    static let humanNames: [String: String] = [
        "sleep_score": "sleep score",
        "readiness_score": "readiness",
        "activity_score": "activity score",
        "avg_hrv": "HRV",
        "lowest_hr_sleep": "lowest sleeping heart rate",
        "deep_sleep_s": "deep sleep",
        "rem_sleep_s": "REM sleep",
        "total_sleep_s": "total sleep",
        "sleep_efficiency": "sleep efficiency",
        "sleep_latency_s": "time to fall asleep",
        "stress_high_s": "stress minutes",
        "steps": "steps",
        "active_calories": "active calories",
        "sedentary_time_s": "sedentary time",
        "bedtime_start_min": "bedtime",
        "meeting_count": "number of meetings",
        "calendar_busy_s": "time in meetings",
        "first_event_min": "first meeting time",
        "screen_total_min": "screen time",
        "screen_late_min": "late-night screen time",
        "mindful_min": "mindfulness minutes",
        "exercise_min": "exercise minutes",
        "caffeine_mg": "caffeine",
        "alcohol_drinks": "alcohol",
        "temp_max_c": "max temperature",
        "daylight_s": "daylight",
        "sunshine_s": "sunshine",
        "temperature_deviation": "body temp deviation",
        "spo2_avg": "blood oxygen",
    ]

    static func human(_ metric: String) -> String {
        if let n = humanNames[metric] { return n }
        if metric.hasPrefix("workout_") {
            return metric.dropFirst("workout_".count).replacingOccurrences(of: "_s", with: "") + " workouts"
        }
        if metric.hasPrefix("tag_") { return "tag: " + metric.dropFirst(4) }
        return metric.replacingOccurrences(of: "_", with: " ")
    }
}
