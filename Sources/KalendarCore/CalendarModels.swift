// What the cache stores (§18.2, §18.3): calendars, event instances, and Google's event color palette.
import Foundation
import GRDB

public struct CalendarInfo: Codable, Equatable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "calendar"

    public var account: String
    public var id: String
    public var summary: String
    /// "#rrggbb"
    public var backgroundColor: String
    public var accessRole: String
    /// Google's "show in list" flag; Kalendar's calendar visibility (§12).
    public var selected: Bool
    public var primary: Bool
    /// Change-stream token; nil until the first full sync finishes.
    public var syncToken: String?
    /// The instance window the cache holds for this calendar.
    public var windowStart: Date?
    public var windowEnd: Date?

    public var key: String { "\(account)|\(id)" }
}

public struct Attendee: Codable, Equatable, Hashable {
    public var email: String
    public var displayName: String?
    public var isSelf: Bool
    public var organizer: Bool
    public var optional: Bool
    /// needsAction, declined, tentative, accepted
    public var responseStatus: String
}

/// One occurrence: a single event, or one instance of a recurring series.
public struct EventInstance: Codable, Equatable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "event"

    public var account: String
    public var calendarId: String
    public var id: String
    /// The series this instance belongs to; nil for a single event.
    public var recurringEventId: String?
    public var summary: String
    public var location: String?
    public var notes: String?
    public var start: Date
    /// Exclusive. For an all-day event, midnight after the last day.
    public var end: Date
    public var allDay: Bool
    public var transparency: String?
    public var colorId: String?
    public var conferenceURL: String?
    /// The signed-in user's response when they are an attendee; nil otherwise.
    public var selfResponse: String?
    public var organizerSelf: Bool
    public var attendees: [Attendee]
    public var htmlLink: String?

    public var key: String { "\(account)|\(calendarId)|\(id)" }
    public var isDeclined: Bool { selfResponse == "declined" }
    /// Not yet accepted: drawn with an open circle (§4.3).
    public var isTentative: Bool { selfResponse == "needsAction" || selfResponse == "tentative" }
}

/// Google's event color palette (`colors.get`), per account.
public struct EventColor: Codable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "eventColor"
    public var account: String
    public var colorId: String
    public var background: String
}
