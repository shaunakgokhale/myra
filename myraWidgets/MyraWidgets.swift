import WidgetKit
import SwiftUI

struct Snapshot {
    var readiness: Double?
    var sleep: Double?
    var hrv: Double?
    var sleepDebtH: Double?
    var updatedAt: Date?

    static func load() -> Snapshot {
        guard let defaults = UserDefaults(suiteName: "group.com.shaunak.myra"),
              let dict = defaults.dictionary(forKey: "widgetSnapshot") as? [String: Double] else {
            return Snapshot()
        }
        return Snapshot(
            readiness: dict["readiness_score"],
            sleep: dict["sleep_score"],
            hrv: dict["avg_hrv"],
            sleepDebtH: dict["sleep_debt_h"],
            updatedAt: defaults.object(forKey: "widgetSnapshotAt") as? Date,
        )
    }
}

struct Entry: TimelineEntry {
    let date: Date
    let snapshot: Snapshot
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: .now, snapshot: Snapshot(readiness: 82, sleep: 78, hrv: 52, sleepDebtH: 1.5, updatedAt: .now))
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: .now, snapshot: Snapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let entry = Entry(date: .now, snapshot: Snapshot.load())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(1800))))
    }
}

// MARK: - Home Screen widget

struct ScoresWidgetView: View {
    let entry: Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Myra")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let debt = entry.snapshot.sleepDebtH, debt > 2 {
                    Text("debt \(debt, specifier: "%.1f")h")
                        .font(.caption2)
                        .foregroundStyle(debt > 5 ? .red : .orange)
                }
            }
            Spacer()
            HStack(spacing: 12) {
                gauge(entry.snapshot.readiness, "Ready", .green)
                gauge(entry.snapshot.sleep, "Sleep", .blue)
                gauge(entry.snapshot.hrv, "HRV", .purple, max: 150)
            }
        }
        .containerBackground(for: .widget) { Color(red: 0.05, green: 0.06, blue: 0.12) }
    }

    private func gauge(_ value: Double?, _ label: String, _ color: Color, max: Double = 100) -> some View {
        VStack(spacing: 4) {
            Gauge(value: min(value ?? 0, max), in: 0...max) {
                EmptyView()
            } currentValueLabel: {
                Text(value.map { "\(Int($0))" } ?? "—")
                    .font(.system(.caption, design: .rounded).bold())
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(color)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct ScoresWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MyraScores", provider: Provider()) { entry in
            ScoresWidgetView(entry: entry)
        }
        .configurationDisplayName("Today's scores")
        .description("Readiness, sleep and HRV at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Lock Screen widgets

struct ReadinessAccessoryView: View {
    let entry: Entry

    var body: some View {
        Gauge(value: min(entry.snapshot.readiness ?? 0, 100), in: 0...100) {
            Image(systemName: "heart.fill")
        } currentValueLabel: {
            Text(entry.snapshot.readiness.map { "\(Int($0))" } ?? "—")
        }
        .gaugeStyle(.accessoryCircular)
        .containerBackground(for: .widget) { Color.clear }
    }
}

struct ReadinessAccessoryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MyraReadinessAccessory", provider: Provider()) { entry in
            ReadinessAccessoryView(entry: entry)
        }
        .configurationDisplayName("Readiness")
        .description("Today's readiness score.")
        .supportedFamilies([.accessoryCircular])
    }
}

struct SleepDebtAccessoryView: View {
    let entry: Entry

    var body: some View {
        HStack {
            Image(systemName: "moon.zzz.fill")
            VStack(alignment: .leading) {
                Text(entry.snapshot.sleepDebtH.map { String(format: "%.1f h sleep debt", $0) } ?? "No debt data")
                    .font(.headline)
                Text(entry.snapshot.sleep.map { "Sleep score \(Int($0))" } ?? "")
                    .font(.caption)
            }
        }
        .containerBackground(for: .widget) { Color.clear }
    }
}

struct SleepDebtAccessoryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MyraSleepDebtAccessory", provider: Provider()) { entry in
            SleepDebtAccessoryView(entry: entry)
        }
        .configurationDisplayName("Sleep debt")
        .description("Your accumulated sleep debt.")
        .supportedFamilies([.accessoryRectangular])
    }
}

@main
struct MyraWidgetBundle: WidgetBundle {
    var body: some Widget {
        ScoresWidget()
        ReadinessAccessoryWidget()
        SleepDebtAccessoryWidget()
    }
}
