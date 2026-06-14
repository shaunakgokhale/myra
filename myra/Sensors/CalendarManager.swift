import Foundation
import EventKit

/// Reads calendar events (past 14 days, next 7) and pushes them to the backend,
/// and can write recovery blocks proposed by the agent.
@Observable
final class CalendarManager {
    static let shared = CalendarManager()

    private let store = EKEventStore()
    var isAuthorized = false

    func requestAccess() async {
        do {
            isAuthorized = try await store.requestFullAccessToEvents()
            if isAuthorized { await sync() }
        } catch {
            print("Calendar access failed: \(error)")
        }
    }

    func sync() async {
        guard isAuthorized else { return }
        let start = Date.now.addingTimeInterval(-14 * 86_400)
        let end = Date.now.addingTimeInterval(7 * 86_400)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate)

        let iso = ISO8601DateFormatter()
        let uploads = events.compactMap { e -> APIClient.CalendarEventUpload? in
            guard let id = e.eventIdentifier else { return nil }
            return .init(
                id: id,
                title: e.title ?? "",
                start: iso.string(from: e.startDate),
                end: iso.string(from: e.endDate),
                allDay: e.isAllDay,
            )
        }
        do {
            try await APIClient.shared.uploadCalendar(uploads)
            UserDefaults.standard.set(Date.now, forKey: "lastCalendarSync")
        } catch {
            print("Calendar upload failed: \(error)")
        }
    }

    /// Write a recovery / wind-down block into the default calendar.
    func addBlock(title: String, start: Date, durationMinutes: Int, notes: String?) async -> Bool {
        guard isAuthorized else { return false }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = start.addingTimeInterval(Double(durationMinutes) * 60)
        event.notes = notes
        event.calendar = store.defaultCalendarForNewEvents
        do {
            try store.save(event, span: .thisEvent)
            return true
        } catch {
            print("Calendar write failed: \(error)")
            return false
        }
    }
}
