import Foundation
import HealthKit

/// Reads daily aggregates from HealthKit and ships them to the backend timeline.
/// Also writes mindfulness sessions back after breathing exercises.
@Observable
final class HealthKitManager {
    static let shared = HealthKitManager()

    private let store = HKHealthStore()
    var isAuthorized = false

    private var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [
            HKQuantityType(.stepCount),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.appleExerciseTime),
            HKQuantityType(.heartRate),
            HKQuantityType(.heartRateVariabilitySDNN),
            HKQuantityType(.restingHeartRate),
            HKQuantityType(.respiratoryRate),
            HKQuantityType(.dietaryCaffeine),
            HKQuantityType(.numberOfAlcoholicBeverages),
            HKQuantityType(.bodyMass),
            HKObjectType.workoutType(),
        ]
        types.insert(HKCategoryType(.mindfulSession))
        return types
    }

    private var writeTypes: Set<HKSampleType> {
        [HKCategoryType(.mindfulSession)]
    }

    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        do {
            try await store.requestAuthorization(toShare: writeTypes, read: Set(readTypes.compactMap { $0 as? HKSampleType }))
            isAuthorized = true
            await syncDailyAggregates()
        } catch {
            print("HealthKit auth failed: \(error)")
        }
    }

    /// Aggregate the last `days` days into daily metrics and upload.
    func syncDailyAggregates(days: Int = 14) async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        var uploads: [APIClient.DailyMetricUpload] = []

        let cal = Calendar.current
        let end = cal.startOfDay(for: .now).addingTimeInterval(86_400)
        let start = cal.date(byAdding: .day, value: -days, to: end)!

        let sums: [(HKQuantityTypeIdentifier, String, HKUnit, Double)] = [
            (.stepCount, "hk_steps", .count(), 1),
            (.activeEnergyBurned, "hk_active_kcal", .kilocalorie(), 1),
            (.appleExerciseTime, "exercise_min", .minute(), 1),
            (.dietaryCaffeine, "caffeine_mg", .gramUnit(with: .milli), 1),
            (.numberOfAlcoholicBeverages, "alcohol_drinks", .count(), 1),
        ]
        for (id, metric, unit, scale) in sums {
            if let byDay = try? await dailyStatistic(.init(id), options: .cumulativeSum, unit: unit, start: start, end: end, take: { $0.sumQuantity() }) {
                for (day, v) in byDay {
                    uploads.append(.init(day: day, source: "healthkit", metric: metric, value: v * scale))
                }
            }
        }

        let averages: [(HKQuantityTypeIdentifier, String, HKUnit)] = [
            (.restingHeartRate, "hk_resting_hr", HKUnit.count().unitDivided(by: .minute())),
            (.heartRateVariabilitySDNN, "hk_hrv_sdnn", .secondUnit(with: .milli)),
        ]
        for (id, metric, unit) in averages {
            if let byDay = try? await dailyStatistic(.init(id), options: .discreteAverage, unit: unit, start: start, end: end, take: { $0.averageQuantity() }) {
                for (day, v) in byDay {
                    uploads.append(.init(day: day, source: "healthkit", metric: metric, value: v))
                }
            }
        }

        // Mindful minutes per day.
        if let mindful = try? await mindfulMinutes(start: start, end: end) {
            for (day, v) in mindful {
                uploads.append(.init(day: day, source: "healthkit", metric: "mindful_min", value: v))
            }
        }

        do {
            try await APIClient.shared.uploadDaily(uploads)
            UserDefaults.standard.set(Date.now, forKey: "lastHealthKitSync")
        } catch {
            print("HealthKit upload failed: \(error)")
        }
    }

    private func dailyStatistic(
        _ id: HKQuantityType,
        options: HKStatisticsOptions,
        unit: HKUnit,
        start: Date,
        end: Date,
        take: @escaping @Sendable (HKStatistics) -> HKQuantity?,
    ) async throws -> [(String, Double)] {
        try await withCheckedThrowingContinuation { cont in
            var interval = DateComponents()
            interval.day = 1
            let q = HKStatisticsCollectionQuery(
                quantityType: id,
                quantitySamplePredicate: HKQuery.predicateForSamples(withStart: start, end: end),
                options: options,
                anchorDate: Calendar.current.startOfDay(for: start),
                intervalComponents: interval,
            )
            q.initialResultsHandler = { _, collection, error in
                if let error { cont.resume(throwing: error); return }
                var out: [(String, Double)] = []
                let fmt = DateFormatter()
                fmt.dateFormat = "yyyy-MM-dd"
                collection?.enumerateStatistics(from: start, to: end) { stat, _ in
                    if let qty = take(stat) {
                        out.append((fmt.string(from: stat.startDate), qty.doubleValue(for: unit)))
                    }
                }
                cont.resume(returning: out)
            }
            store.execute(q)
        }
    }

    private func mindfulMinutes(start: Date, end: Date) async throws -> [(String, Double)] {
        try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(
                sampleType: HKCategoryType(.mindfulSession),
                predicate: HKQuery.predicateForSamples(withStart: start, end: end),
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil,
            ) { _, samples, error in
                if let error { cont.resume(throwing: error); return }
                let fmt = DateFormatter()
                fmt.dateFormat = "yyyy-MM-dd"
                var byDay: [String: Double] = [:]
                for s in samples ?? [] {
                    let day = fmt.string(from: s.startDate)
                    byDay[day, default: 0] += s.endDate.timeIntervalSince(s.startDate) / 60
                }
                cont.resume(returning: byDay.map { ($0.key, $0.value) })
            }
            store.execute(q)
        }
    }

    /// Write a completed breathing session as mindfulness.
    func logMindfulSession(start: Date, end: Date) async {
        let sample = HKCategorySample(
            type: HKCategoryType(.mindfulSession),
            value: HKCategoryValue.notApplicable.rawValue,
            start: start,
            end: end,
        )
        try? await store.save(sample)
        await syncDailyAggregates(days: 1)
    }

    /// Recent intraday heart rate (for stress-spike detection while app is active).
    func recentHeartRate(minutes: Int = 30) async -> [(Date, Double)] {
        await withCheckedContinuation { cont in
            let start = Date.now.addingTimeInterval(-Double(minutes) * 60)
            let q = HKSampleQuery(
                sampleType: HKQuantityType(.heartRate),
                predicate: HKQuery.predicateForSamples(withStart: start, end: .now),
                limit: 200,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)],
            ) { _, samples, _ in
                let unit = HKUnit.count().unitDivided(by: .minute())
                let out = (samples as? [HKQuantitySample])?.map { ($0.startDate, $0.quantity.doubleValue(for: unit)) } ?? []
                cont.resume(returning: out)
            }
            store.execute(q)
        }
    }
}
