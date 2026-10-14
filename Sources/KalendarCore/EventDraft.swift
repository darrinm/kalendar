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
    /// Asks Google to create a Meet conference for the event when it is written (§5.1).
    public var addGoogleMeet = false

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

    /// A new event's draft from parsed input (§5): all-day events are free with no alerts (§5.2),
    /// timed ones busy with the calendar's default alerts unless the text named some.
    public init(parsed p: ParsedItem, account: String, calendarId: String, timeZone: String = TimeZone.current.identifier) {
        summary = p.title
        location = p.location ?? ""
        notes = ""
        allDay = p.allDay
        start = p.start
        end = p.end
        self.timeZone = timeZone
        self.account = account
        self.calendarId = calendarId
        colorId = nil
        busy = !p.allDay
        visibility = "default"
        reminders = p.alerts.isEmpty ? Reminders(useDefault: !p.allDay, minutes: [])
                                     : Reminders(useDefault: false, minutes: p.alerts)
        recurrence = p.recurrence
        attendees = []
    }

    /// The draft for new parsed input, keeping every field the user changed by hand: a field
    /// whose value still equals the previous parse follows the new parse (§5.2's live form).
    public func following(_ newParse: EventDraft, previousParse old: EventDraft) -> EventDraft {
        var d = self
        func take<T: Equatable>(_ key: WritableKeyPath<EventDraft, T>) {
            if self[keyPath: key] == old[keyPath: key] { d[keyPath: key] = newParse[keyPath: key] }
        }
        take(\.summary); take(\.location); take(\.allDay); take(\.start); take(\.end); take(\.account)
        take(\.calendarId); take(\.busy); take(\.reminders); take(\.recurrence); take(\.attendees)
        return d
    }

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
        if addGoogleMeet && !original.addGoogleMeet { body["conferenceData"] = Self.meetRequest() }
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
        if addGoogleMeet { body["conferenceData"] = Self.meetRequest() }
        return body
    }

    /// Google creates the Meet conference for a write carrying this and `conferenceDataVersion=1`.
    /// The request id only has to be unique per request.
    static func meetRequest() -> [String: Any] {
        ["createRequest": ["requestId": UUID().uuidString, "conferenceSolutionKey": ["type": "hangoutsMeet"]]]
    }

    /// `query` for a write of `body`, with `conferenceDataVersion=1` when the body carries
    /// `conferenceData`, which Google ignores without it.
    public static func query(_ query: [String: String], for body: [String: Any]?) -> [String: String] {
        body?["conferenceData"] == nil ? query : query.merging(["conferenceDataVersion": "1"]) { a, _ in a }
    }

    /// Invites `guests` (email, name), each once and never the organizer: the organizer is listed
    /// with them, accepted, as Google does. No guests, no attendees.
    public mutating func invite(_ guests: [(email: String, name: String?)]) {
        var seen: Set<String> = [account.lowercased()]
        let unique = guests.filter { seen.insert($0.email.lowercased()).inserted }
        attendees = unique.isEmpty ? [] : [Attendee(email: account, displayName: nil, isSelf: true, organizer: true,
                                                    optional: false, responseStatus: "accepted")]
            + unique.map { Attendee(email: $0.email, displayName: $0.name, isSelf: false, organizer: false,
                                    optional: false, responseStatus: "needsAction") }
    }

    /// Writing `date` clears `dateTime` and the reverse, so switching all-day on or off patches cleanly.
    static func time(_ date: Date, allDay: Bool, timeZone: String, calendar: Calendar) -> [String: Any] {
        if allDay {
            return ["date": GoogleCalendarAPI.ymd(date, calendar: calendar), "dateTime": NSNull(), "timeZone": NSNull()]
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
