import Foundation
import SwiftUI
import UserNotifications
import WidgetKit

@Observable
final class AppState {
    static let shared = AppState()

    var dashboard = Dashboard()
    var insights: Insights?
    var experiments: [Experiment] = []
    var status: BackendStatus?
    var isLoading = false
    var lastError: String?

    var backendConfigured: Bool { APIClient.shared.isConfigured }

    func refreshAll() async {
        guard backendConfigured else { return }
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        // Keep the server's scheduler in sync with the device's chosen engine,
        // so wake-vs-Claude behavior always matches the user's setting.
        Task.detached { try? await APIClient.shared.setAgentEngine(AgentEngine.current.rawValue) }

        status = try? await APIClient.shared.status()
        do {
            let d = try await APIClient.shared.dashboard()
            dashboard = d
            ScreenTimeManager.shared.enforce(policy: d.shieldPolicy)
            await applyCalendarBlock(d.calendarBlock)
            publishWidgetSnapshot(d)
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }

        // Fire-and-forget background syncs from device sensors.
        Task.detached { await HealthKitManager.shared.syncDailyAggregates() }
        Task.detached { await CalendarManager.shared.sync() }

        insights = try? await APIClient.shared.insights()
        experiments = (try? await APIClient.shared.experiments()) ?? []

        await checkStressSpike()
    }

    /// If the last ~20 minutes of heart rate run well above resting baseline,
    /// nudge a 2-minute breathing session (at most once every 2 hours).
    private func checkStressSpike() async {
        let last = UserDefaults.standard.object(forKey: "lastStressNudge") as? Date ?? .distantPast
        guard Date.now.timeIntervalSince(last) > 2 * 3600 else { return }
        guard let restingHR = dashboard.median("hk_resting_hr", last: 14)
            ?? dashboard.median("lowest_hr_sleep", last: 14).map({ $0 + 10 }) else { return }

        let samples = await HealthKitManager.shared.recentHeartRate(minutes: 20)
        guard samples.count >= 5 else { return }
        let avg = samples.map(\.1).reduce(0, +) / Double(samples.count)
        let threshold = restingHR * 1.35

        if avg > threshold {
            UserDefaults.standard.set(Date.now, forKey: "lastStressNudge")
            let content = UNMutableNotificationContent()
            content.title = "Heart rate elevated"
            content.body = "Averaging \(Int(avg)) bpm for 20 minutes (resting \(Int(restingHR))). Two minutes of breathing will bring it down — open Myra."
            content.sound = .default
            let req = UNNotificationRequest(identifier: "stress-\(Date.now.timeIntervalSince1970)", content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(req)
        }
    }

    /// Share today's scores with the widget via the app group.
    private func publishWidgetSnapshot(_ dash: Dashboard) {
        guard let defaults = UserDefaults(suiteName: "group.com.shaunak.myra") else { return }
        var snapshot: [String: Double] = [:]
        for key in ["readiness_score", "sleep_score", "activity_score", "avg_hrv", "total_sleep_s"] {
            if let v = dash.latest(key) { snapshot[key] = v }
        }
        if let debt = dash.sleepDebt { snapshot["sleep_debt_h"] = debt.debtHours }
        defaults.set(snapshot, forKey: "widgetSnapshot")
        defaults.set(Date.now, forKey: "widgetSnapshotAt")
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Write an agent-proposed recovery/wind-down block into the calendar, once.
    private func applyCalendarBlock(_ proposal: CalendarBlockProposal?) async {
        guard let proposal,
              CalendarManager.shared.isAuthorized,
              UserDefaults.standard.string(forKey: "lastAppliedCalendarBlock") != proposal.proposedAt,
              let start = ISO8601DateFormatter().date(from: proposal.start),
              start > .now
        else { return }

        let ok = await CalendarManager.shared.addBlock(
            title: proposal.title,
            start: start,
            durationMinutes: proposal.durationMinutes,
            notes: proposal.notes,
        )
        if ok {
            UserDefaults.standard.set(proposal.proposedAt, forKey: "lastAppliedCalendarBlock")
        }
    }
}
