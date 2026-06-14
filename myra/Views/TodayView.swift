import SwiftUI
import Charts

struct TodayView: View {
    @Environment(AppState.self) private var state
    @State private var showBreathing = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        errorBanner
                        connectBanner
                        scoresCard
                        briefingCard
                        sleepDebtCard
                        sleepDetailCard
                        actionRow
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 24)
                }
                .refreshable { await state.refreshAll() }
            }
            .navigationTitle(greeting)
            .sheet(isPresented: $showBreathing) { BreathingView() }
        }
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: .now)
        if h < 5 { return "Late night" }
        if h < 12 { return "Good morning" }
        if h < 18 { return "Good afternoon" }
        return "Good evening"
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let err = state.lastError {
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Couldn't load data", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.warning)
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private var connectBanner: some View {
        if let status = state.status, !status.ouraConnected {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Connect your Oura ring", systemImage: "circle.circle")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text("Myra needs your ring data to start learning your patterns.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                    if let url = URL(string: status.oauthStartUrl) {
                        Link("Connect Oura", destination: url)
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.readiness)
                    }
                }
            }
        }
    }

    private var scoresCard: some View {
        Card {
            HStack(spacing: 0) {
                ring("readiness_score", "Readiness", Theme.readiness)
                ring("sleep_score", "Sleep", Theme.sleep)
                ring("activity_score", "Activity", Theme.activity)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func ring(_ metric: String, _ label: String, _ color: Color) -> some View {
        Group {
            if let v = state.dashboard.latest(metric) {
                ScoreRing(score: v, label: label, color: color)
            } else {
                ScoreRing(score: 0, label: label, color: color.opacity(0.4))
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var briefingCard: some View {
        if let msg = state.dashboard.latestMessage {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Myra says", systemImage: "sparkles")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.hrv)
                    Text(msg.content)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textPrimary)
                        .lineSpacing(3)
                }
            }
        }
    }

    @ViewBuilder
    private var sleepDebtCard: some View {
        if let debt = state.dashboard.sleepDebt {
            Card {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Sleep debt (14d)")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                        Text("\(debt.debtHours, specifier: "%.1f") h")
                            .font(.title2.bold())
                            .foregroundStyle(debt.debtHours > 5 ? Theme.warning : Theme.textPrimary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        Text("Your need: \(debt.personalNeedHours, specifier: "%.1f") h")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                        Text("7d avg: \(debt.last7AvgHours, specifier: "%.1f") h")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                        if let w = state.dashboard.optimalBedtime {
                            Text("Best bedtime: \(w.bestBedtimeLabel)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.sleep)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var sleepDetailCard: some View {
        if let night = state.dashboard.lastNight {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "Last night")
                    HStack(spacing: 14) {
                        stat("Total", hours(night["total_sleep_s"]))
                        stat("Deep", hours(night["deep_sleep_s"]))
                        stat("REM", hours(night["rem_sleep_s"]))
                        stat("HRV", night["avg_hrv"].map { "\(Int($0))" } ?? "—")
                        stat("Low HR", night["lowest_hr_sleep"].map { "\(Int($0))" } ?? "—")
                    }
                }
            }
        }
    }

    private func hours(_ s: Double?) -> String {
        guard let s else { return "—" }
        let h = Int(s) / 3600
        let m = (Int(s) % 3600) / 60
        return "\(h):\(String(format: "%02d", m))"
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(.callout, design: .rounded).weight(.bold))
                .foregroundStyle(Theme.textPrimary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button {
                showBreathing = true
            } label: {
                Label("Breathe", systemImage: "wind")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            .tint(Theme.sleep)

            if let policy = state.dashboard.shieldPolicy, policy.strictness > 0 {
                Label("Shield \(policy.winddownTime)", systemImage: "moon.zzz.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(Theme.hrv)
            }
        }
    }
}
