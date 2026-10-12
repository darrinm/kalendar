// The detail popover's editable fields (§6, §6.1), and the Google `events.patch` body that turns an
// edited draft back into a write.
import Foundation

public struct EventDraft: Equatable {
    public var summary: String
    public var location: String
    public var notes: String
    public var allDay: Bool
    public var start: Date
    /// Exclusive, like Google's: for an all-day event, midnight after the last day.
    public var end: Date
    public var timeZone: String
    public var account: String
    public var calendarId: String
    /// nil: the calendar's color.
    public var colorId: String?
    public var busy: Bool
    /// default, public, private, confidential
    public var visibility: String
    public var reminders: Reminders
    /// The series rule; nil for a one-off event.
    public var recurrence: RecurrenceRule?
    public var attendees: [Attendee]

    public init(_ e: EventInstance, recurrence: RecurrenceRule?) {
        summary = e.summary == "(No title)" ? "" : e.summary
        location = e.location ?? ""
        notes = e.notes ?? ""
        allDay = e.allDay
        start = e.start
        end = e.end
        timeZone = e.timeZone ?? TimeZone.current.identifier
        account = e.account
        calendarId = e.calendarId
        colorId = e.colorId
        busy = e.transparency != "transparent"
        visibility = e.visibility ?? "default"
        reminders = e.reminders
        self.recurrence = recurrence
        attendees = e.attendees
    }

    public var calendarKey: String { "\(account)|\(calendarId)" }

    /// The patch body for what differs from `original`, or nil when nothing does.
    ///
    /// `seriesTimes` is the master event's start and end when the edit applies to all occurrences
    /// (§8.1): times are then written as the master's, shifted by however far this occurrence moved.
    public func patchBody(from original: EventDraft, seriesTimes: (start: Date, end: Date)? = nil,
                          calendar: Calendar = .current) -> [String: Any]? {
        var body: [String: Any] = [:]
        if summary != original.summary { body["summary"] = summary }
        if location != original.location { body["location"] = location }
        if notes != original.notes { body["description"] = notes }
        if allDay != original.allDay || start != original.start || end != original.end || timeZone != original.timeZone {
            var newStart = start, newEnd = end
            if let seriesTimes {
                newStart = seriesTimes.start.addingTimeInterval(start.timeIntervalSince(original.start))
                newEnd = seriesTimes.end.addingTimeInterval(end.timeIntervalSince(original.end))
            }
            body["start"] = Self.time(newStart, allDay: allDay, timeZone: timeZone, calendar: calendar)
            body["end"] = Self.time(newEnd, allDay: allDay, timeZone: timeZone, calendar: calendar)
        }
        if colorId != original.colorId { body["colorId"] = colorId ?? NSNull() }
        if busy != original.busy { body["transparency"] = busy ? "opaque" : "transparent" }
        if visibility != original.visibility { body["visibility"] = visibility }
        if reminders != original.reminders { body["reminders"] = Self.reminders(reminders) }
        if recurrence != original.recurrence {
            body["recurrence"] = recurrence.map { [$0.rrule(calendar: calendar, allDay: allDay)] } ?? []
        }
        if attendees != original.attendees { body["attendees"] = attendees.map(Self.attendee) }
        return body.isEmpty ? nil : body
    }

    /// The body for `events.insert`: every field, for a copy (Duplicate, undo of a delete). A copy
    /// without `guests` sends nobody an invitation.
    public func insertBody(guests: Bool = true, calendar: Calendar = .current) -> [String: Any] {
        var body: [String: Any] = [
            "summary": summary,
            "start": Self.time(start, allDay: allDay, timeZone: timeZone, calendar: calendar),
            "end": Self.time(end, allDay: allDay, timeZone: timeZone, calendar: calendar),
            "transparency": busy ? "opaque" : "transparent",
            "visibility": visibility,
            "reminders": Self.reminders(reminders),
        ]
        if !location.isEmpty { body["location"] = location }
        if !notes.isEmpty { body["description"] = notes }
        if let colorId { body["colorId"] = colorId }
        if let recurrence { body["recurrence"] = [recurrence.rrule(calendar: calendar, allDay: allDay)] }
        if guests && !attendees.isEmpty { body["attendees"] = attendees.map(Self.attendee) }
        return body
    }

    /// Writing `date` clears `dateTime` and the reverse, so switching all-day on or off patches cleanly.
    static func time(_ date: Date, allDay: Bool, timeZone: String, calendar: Calendar) -> [String: Any] {
        if allDay {
            let c = calendar.dateComponents([.year, .month, .day], from: date)
            return ["date": String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!),
                    "dateTime": NSNull(), "timeZone": NSNull()]
        }
        return ["dateTime": GoogleCalendarAPI.iso(date), "timeZone": timeZone, "date": NSNull()]
    }

    static func reminders(_ r: Reminders) -> [String: Any] {
        r.useDefault
            ? ["useDefault": true]
            : ["useDefault": false, "overrides": r.minutes.map { ["method": "popup", "minutes": $0] }]
    }

    static func attendee(_ a: Attendee) -> [String: Any] {
        var d: [String: Any] = ["email": a.email, "responseStatus": a.responseStatus]
        if a.optional { d["optional"] = true }
        if let name = a.displayName { d["displayName"] = name }
        return d
    }

    /// The RSVP patch (§6): every attendee, with only the user's response changed, since `patch`
    /// replaces arrays rather than merging them.
    public static func rsvpBody(attendees: [Attendee], response: String) -> [String: Any] {
        ["attendees": attendees.responding(response).map(attendee)]
    }
}
