// Which event alerts to schedule (§19): popup reminders that fire in the next 24 hours.
import Foundation

public struct PlannedAlert: Equatable {
    /// `<calendarId>|<eventId>|<minutes>`: rescheduling replaces the request, and an alert whose
    /// event is gone is not planned again, so it is removed.
    public var identifier: String
    public var fireDate: Date
    public var event: EventInstance
}

public enum AlertPlanner {
    public static let horizon: TimeInterval = 86400
    /// macOS keeps at most 64 pending notifications per app.
    public static let limit = 64
    /// Google allows reminders up to four weeks before the start.
    public static let maxLead: TimeInterval = 4 * 7 * 86400

    /// The events whose alerts can fire within the horizon: those that start before it plus the
    /// longest lead time. The cache returns visible calendars only.
    public static func candidates(in cache: CalendarCache, now: Date) throws -> [EventInstance] {
        try cache.events(from: now, to: now.addingTimeInterval(horizon + maxLead))
    }

    /// The alerts firing in (now, now + horizon], earliest first, at most `limit`. The event's own
    /// popup reminders, or its calendar's defaults when it uses them; the calendar's defaults are for
    /// timed events, so an all-day event using them gets none. Declined events get none. An event on
    /// several calendars (same title, times and location) alerts once, from the first copy that has
    /// reminders. An all-day event's start is local midnight, so its reminders count back from 00:00.
    public static func plan(events: [EventInstance], calendars: [String: CalendarInfo], now: Date,
                            limit: Int = limit) -> [PlannedAlert] {
        var seen = Set<EventInstance.DuplicateKey>()
        var result: [PlannedAlert] = []
        for e in events where !e.isDeclined {
            let minutes = e.reminders.useDefault
                ? (e.allDay ? [] : calendars[e.calendarKey]?.defaultReminders ?? [])
                : e.reminders.minutes
            guard !minutes.isEmpty,
                  seen.insert(e.duplicateKey).inserted
            else { continue }
            for m in Set(minutes) {
                let fire = e.start.addingTimeInterval(-Double(m) * 60)
                guard fire > now, fire <= now.addingTimeInterval(horizon) else { continue }
                result.append(PlannedAlert(identifier: "\(e.calendarId)|\(e.id)|\(m)", fireDate: fire, event: e))
            }
        }
        return Array(result.sorted { ($0.fireDate, $0.identifier) < ($1.fireDate, $1.identifier) }.prefix(max(limit, 0)))
    }
}
