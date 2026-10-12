// Which event alerts to schedule (§19): popup reminders that fire in the next 24 hours.
import Foundation

public struct PlannedAlert: Equatable {
    /// `<calendarId>|<eventId>|<minutes>`: rescheduling replaces the request, and an alert whose
    /// event is gone is not planned again, so it is removed.
    public var identifier: String
    public var fireDate: Date
    public var minutes: Int
    public var event: EventInstance
}

public enum AlertPlanner {
    public static let horizon: TimeInterval = 86400
    /// macOS keeps at most 64 pending notifications per app.
    public static let limit = 64
    /// Google allows reminders up to four weeks before the start.
    public static let maxLead: TimeInterval = 4 * 7 * 86400

    public static func identifier(calendarId: String, eventId: String, minutes: Int) -> String {
        "\(calendarId)|\(eventId)|\(minutes)"
    }

    /// The events whose alerts can fire within the horizon: those that start before it plus the
    /// longest lead time. The cache returns visible calendars only.
    public static func candidates(in cache: CalendarCache, now: Date) throws -> [EventInstance] {
        try cache.events(from: now, to: now.addingTimeInterval(horizon + maxLead))
    }

    /// The alerts firing in (now, now + horizon], earliest first, at most `limit`. The event's own
    /// popup reminders, or its calendar's defaults when it uses them. Declined events get none. An
    /// event on several calendars (same title, times and location) alerts once. An all-day event's
    /// start is local midnight, so its reminders count back from 00:00.
    public static func plan(events: [EventInstance], calendars: [String: CalendarInfo], now: Date) -> [PlannedAlert] {
        struct Same: Hashable { var summary: String; var start: Date; var end: Date; var location: String? }
        var seen = Set<Same>()
        var result: [PlannedAlert] = []
        for e in events where !e.isDeclined
            && seen.insert(Same(summary: e.summary, start: e.start, end: e.end, location: e.location)).inserted {
            let minutes = e.reminders.useDefault ? calendars[e.calendarKey]?.defaultReminders ?? [] : e.reminders.minutes
            for m in Set(minutes) {
                let fire = e.start.addingTimeInterval(-Double(m) * 60)
                guard fire > now, fire <= now.addingTimeInterval(horizon) else { continue }
                result.append(PlannedAlert(identifier: identifier(calendarId: e.calendarId, eventId: e.id, minutes: m),
                                           fireDate: fire, minutes: m, event: e))
            }
        }
        return Array(result.sorted { ($0.fireDate, $0.identifier) < ($1.fireDate, $1.identifier) }.prefix(limit))
    }
}
