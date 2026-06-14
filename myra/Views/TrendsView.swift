import SwiftUI
import Charts

struct TrendsView: View {
    @Environment(AppState.self) private var state
    @State private var range = 30

    private let charts: [(metric: String, title: String, color: Color, transform: (Double) -> Double, unit: String)] = [
        ("readiness_score", "Readiness", Theme.readiness, { $0 }, ""),
        ("sleep_score", "Sleep score", Theme.sleep, { $0 }, ""),
        ("avg_hrv", "Sleeping HRV", Theme.hrv, { $0 }, "ms"),
        ("lowest_hr_sleep", "Lowest sleeping HR", Theme.warning, { $0 }, "bpm"),
        ("total_sleep_s", "Total sleep", Theme.sleep, { $0 / 3600 }, "h"),
        ("deep_sleep_s", "Deep sleep", Theme.sleep, { $0 / 3600 }, "h"),
        ("steps", "Steps", Theme.activity, { $0 }, ""),
        ("stress_high_s", "Stress minutes", Theme.warning, { $0 / 60 }, "min"),
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        Picker("Range", selection: $range) {
                            Text("30d").tag(30)
                            Text("60d").tag(60)
                            Text("90d").tag(90)
                        }
                        .pickerStyle(.segmented)

                        ForEach(charts, id: \.metric) { spec in
                            trendCard(spec)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Trends")
        }
    }

    @ViewBuilder
    private func trendCard(_ spec: (metric: String, title: String, color: Color, transform: (Double) -> Double, unit: String)) -> some View {
        let series = state.dashboard.series(spec.metric, last: range).map { (date: $0.date, value: spec.transform($0.value)) }
        if series.count >= 2 {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(spec.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        if let last = series.last {
                            Text("\(last.value, specifier: spec.unit == "h" ? "%.1f" : "%.0f")\(spec.unit.isEmpty ? "" : " " + spec.unit)")
                                .font(.subheadline.bold())
                                .foregroundStyle(spec.color)
                        }
                    }
                    Chart(series, id: \.date) { point in
                        LineMark(x: .value("Day", point.date), y: .value(spec.title, point.value))
                            .foregroundStyle(spec.color)
                            .interpolationMethod(.catmullRom)
                        AreaMark(x: .value("Day", point.date), y: .value(spec.title, point.value))
                            .foregroundStyle(
                                LinearGradient(colors: [spec.color.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom)
                            )
                            .interpolationMethod(.catmullRom)
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: max(range / 5, 1))) {
                            AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .chartYAxis {
                        AxisMarks {
                            AxisGridLine().foregroundStyle(Color.white.opacity(0.06))
                            AxisValueLabel().foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .frame(height: 130)
                }
            }
        }
    }
}
