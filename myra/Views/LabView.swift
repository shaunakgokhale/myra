import SwiftUI

/// The Lab: discovered patterns (real statistics) and n=1 experiments.
struct LabView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        experimentsSection
                        patternsSection
                        comparisonSection
                        reportsSection
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 24)
                }
                .refreshable { await state.refreshAll() }
            }
            .navigationTitle("Lab")
        }
    }

    // MARK: Experiments

    @ViewBuilder
    private var experimentsSection: some View {
        let active = state.experiments.filter { $0.status == "active" }
        let done = state.experiments.filter { $0.status == "completed" || $0.result != nil }

        if !active.isEmpty || !done.isEmpty {
            VStack(spacing: 12) {
                SectionHeader(title: "Experiments")
                ForEach(active) { exp in
                    ExperimentCard(experiment: exp, isActive: true)
                }
                ForEach(done.filter { e in !active.contains(where: { $0.id == e.id }) }) { exp in
                    ExperimentCard(experiment: exp, isActive: false)
                }
            }
        } else {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Label("No experiments yet", systemImage: "testtube.2")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text("Once Myra has a few weeks of data, the weekly report will propose n=1 experiments — e.g. \"no caffeine after 14:00 for two weeks\" — and measure the real effect on your body.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    // MARK: Patterns

    @ViewBuilder
    private var patternsSection: some View {
        VStack(spacing: 12) {
            SectionHeader(title: "Discovered patterns")
            if let insights = state.insights, !insights.correlations.isEmpty {
                ForEach(insights.correlations.prefix(10)) { c in
                    Card {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: c.r > 0 ? "arrow.up.right" : "arrow.down.right")
                                .font(.headline)
                                .foregroundStyle(c.r > 0 ? Theme.readiness : Theme.warning)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(describe(c))
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.textPrimary)
                                Text("r = \(c.r, specifier: "%.2f") · p = \(c.p, specifier: "%.3f") · \(c.n) days")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                }
            } else {
                Card {
                    Text("Patterns appear after ~2 weeks of combined data. The more sources you connect (HealthKit, calendar), the more Myra discovers.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private func describe(_ c: Correlation) -> String {
        let x = MetricNames.human(c.x)
        let y = MetricNames.human(c.y)
        let direction = c.r > 0 ? "higher" : "lower"
        let when = c.lag == 1 ? "the next day's" : "that day's"
        return "More \(x) → \(direction) \(when) \(y)"
    }

    // MARK: Engine comparison (shadow phase)

    struct EngineComparison: Identifiable {
        let kind: String
        let primary: String?   // Claude (or current primary)
        let apple: String?     // on-device Apple shadow output
        var id: String { kind }
    }

    @State private var comparisons: [EngineComparison] = []

    @ViewBuilder
    private var comparisonSection: some View {
        if !comparisons.isEmpty {
            VStack(spacing: 12) {
                SectionHeader(title: "Engine comparison")
                ForEach(comparisons) { cmp in
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(label(for: cmp.kind))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.hrv)
                            comparisonColumn("CLAUDE", text: cmp.primary, color: Theme.sleep)
                            Divider().overlay(Theme.textSecondary.opacity(0.3))
                            comparisonColumn("APPLE ON-DEVICE", text: cmp.apple, color: Theme.readiness)
                        }
                    }
                }
            }
            .task { await loadComparisons() }
        } else {
            Color.clear.frame(height: 0).task { await loadComparisons() }
        }
    }

    private func comparisonColumn(_ title: String, text: String?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(color)
            Text(text ?? "—")
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func loadComparisons() async {
        var result: [EngineComparison] = []
        for kind in ["briefing", "winddown", "weekly"] {
            let shadow = (try? await APIClient.shared.messages(kind: "\(kind)_shadow")) ?? []
            let primary = (try? await APIClient.shared.messages(kind: kind)) ?? []
            if shadow.first != nil {
                result.append(EngineComparison(kind: kind, primary: primary.first?.content, apple: shadow.first?.content))
            }
        }
        comparisons = result
    }

    // MARK: Reports

    @State private var reports: [AgentMessage] = []

    @ViewBuilder
    private var reportsSection: some View {
        VStack(spacing: 12) {
            SectionHeader(title: "Reports")
            if reports.isEmpty {
                Card {
                    Text("Morning briefings, wind-downs and weekly reports will collect here.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            ForEach(reports.prefix(10)) { msg in
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(label(for: msg.kind))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.hrv)
                        Text(msg.content)
                            .font(.subheadline)
                            .foregroundStyle(Theme.textPrimary)
                            .lineSpacing(3)
                    }
                }
            }
        }
        .task { reports = (try? await APIClient.shared.messages()) ?? [] }
    }

    private func label(for kind: String) -> String {
        switch kind {
        case "briefing": return "MORNING BRIEFING"
        case "winddown": return "WIND-DOWN"
        case "weekly": return "WEEKLY REPORT"
        default: return kind.uppercased()
        }
    }
}

struct ExperimentCard: View {
    let experiment: Experiment
    let isActive: Bool
    @State private var logged = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(isActive ? "ACTIVE" : verdictLabel)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(badgeColor.opacity(0.2), in: Capsule())
                        .foregroundStyle(badgeColor)
                    Spacer()
                    Text("\(String(experiment.start_day.prefix(10))) → \(String(experiment.end_day.prefix(10)))")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
                Text(experiment.hypothesis)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(experiment.intervention)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)

                if let r = experiment.result, let delta = r.deltaPct, let d = r.cohensD {
                    Text("\(MetricNames.human(experiment.target_metric)): \(delta >= 0 ? "+" : "")\(delta, specifier: "%.1f")% (d = \(d, specifier: "%.2f"))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(delta >= 0 ? Theme.readiness : Theme.warning)
                }

                if isActive {
                    HStack(spacing: 10) {
                        Text(logged ? "Logged for today" : "Did you comply today?")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        if !logged {
                            Button("Yes") { log(true) }
                                .buttonStyle(.bordered)
                                .tint(Theme.readiness)
                                .controlSize(.small)
                            Button("No") { log(false) }
                                .buttonStyle(.bordered)
                                .tint(Theme.warning)
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    private var verdictLabel: String {
        switch experiment.result?.verdict {
        case "improved": return "IMPROVED"
        case "worsened": return "WORSENED"
        case "no_clear_effect": return "NO CLEAR EFFECT"
        default: return experiment.status.uppercased()
        }
    }

    private var badgeColor: Color {
        if isActive { return Theme.sleep }
        switch experiment.result?.verdict {
        case "improved": return Theme.readiness
        case "worsened": return Theme.warning
        default: return Theme.textSecondary
        }
    }

    private func log(_ complied: Bool) {
        logged = true
        Task { try? await APIClient.shared.logExperiment(id: experiment.id, complied: complied) }
    }
}
