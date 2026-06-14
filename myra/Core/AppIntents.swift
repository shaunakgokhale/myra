import AppIntents

/// Siri / Shortcuts: "How recovered am I?", "Ask Myra …"
struct HowRecoveredIntent: AppIntent {
    static let title: LocalizedStringResource = "How recovered am I?"
    static let description = IntentDescription("Get today's readiness, sleep and HRV from Myra.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let dash = try await APIClient.shared.dashboard(days: 7)
        guard let today = dash.today else {
            return .result(dialog: "No data yet — open Myra and sync your ring.")
        }
        var parts: [String] = []
        if let r = today["readiness_score"] { parts.append("Readiness \(Int(r))") }
        if let s = today["sleep_score"] { parts.append("sleep \(Int(s))") }
        if let h = today["avg_hrv"] { parts.append("HRV \(Int(h))") }
        if let debt = dash.sleepDebt, debt.debtHours > 2 {
            parts.append("sleep debt \(String(format: "%.1f", debt.debtHours)) hours")
        }
        let dialog = parts.isEmpty ? "No scores for today yet." : parts.joined(separator: ", ") + "."
        return .result(dialog: IntentDialog(stringLiteral: dialog))
    }
}

struct AskMyraIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Myra"
    static let description = IntentDescription("Ask your health agent anything about your body and habits.")

    @Parameter(title: "Question")
    var question: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let reply = try await APIClient.shared.sendChat(question)
        return .result(dialog: IntentDialog(stringLiteral: reply))
    }
}

struct StartBreathingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start breathing session"
    static let description = IntentDescription("Open Myra's 2-minute breathing session.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        // The app opens; the user taps Start. (Deep-link routing kept simple.)
        return .result()
    }
}

struct MyraShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: HowRecoveredIntent(),
            phrases: ["How recovered am I in \(.applicationName)", "\(.applicationName) readiness"],
            shortTitle: "Recovery",
            systemImageName: "heart.fill",
        )
        AppShortcut(
            intent: AskMyraIntent(),
            phrases: ["Ask \(.applicationName)"],
            shortTitle: "Ask Myra",
            systemImageName: "bubble.left.fill",
        )
    }
}
