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
    /// Popup reminders (minutes before) for events that use the calendar's defaults.
    public var defaultReminders: [Int] = []

    public var key: String { "\(account)|\(id)" }
    /// Whether the user can add and edit events on it.
    public var isWritable: Bool { accessRole == "owner" || accessRole == "writer" }
    /// For a calendar or event Google gave no color.
    public static let fallbackColor = "#9A9A9A"
}

public struct Attendee: Codable, Equatable, Hashable {
    public var email: String
    public var displayName: String?
    public var isSelf: Bool
    public var organizer: Bool
    public var optional: Bool
    /// needsAction, declined, tentative, accepted
    public var responseStatus: String

    public init(email: String, displayName: String?, isSelf: Bool, organizer: Bool, optional: Bool, responseStatus: String) {
        self.email = email
        self.displayName = displayName
        self.isSelf = isSelf
        self.organizer = organizer
        self.optional = optional
        self.responseStatus = responseStatus
    }
}

extension Array where Element == Attendee {
    /// The list with the signed-in user's response set to `response`.
    public func responding(_ response: String) -> [Attendee] {
        map { a in
            var a = a
            if a.isSelf { a.responseStatus = response }
            return a
        }
    }
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
    /// Google's version tag; writes send it as `If-Match` (§18.3).
    public var etag: String?
    /// default, public, private, confidential
    public var visibility: String?
    public var reminders: Reminders = Reminders()
    /// The time zone of a timed event's start, an IANA identifier.
    public var timeZone: String?

    public var key: String { "\(account)|\(calendarId)|\(id)" }
    /// The `CalendarInfo.key` of the event's calendar.
    public var calendarKey: String { "\(account)|\(calendarId)" }
    public var isDeclined: Bool { selfResponse == "declined" }

    /// The same event on several calendars shows once and alerts once (§4.3, §19).
    public struct DuplicateKey: Hashable {
        var summary: String
        var start: Date
        var end: Date
        var location: String?
    }
    public var duplicateKey: DuplicateKey { DuplicateKey(summary: summary, start: start, end: end, location: location) }
    /// The user's copy of someone else's event with guests: Kalendar can change only the user's
    /// own alerts, color and busy/free, and cannot restore it after a delete (§6, §8.2).
    public var isInvitation: Bool { !organizerSelf && !attendees.isEmpty }
    /// Not yet accepted: drawn with an open circle (§4.3).
    public var isTentative: Bool { selfResponse == "needsAction" || selfResponse == "tentative" }
}

/// An event's popup alerts (§6.1): the calendar's defaults, or its own list of minutes-before.
public struct Reminders: Codable, Equatable, Hashable {
    public var useDefault: Bool
    public var minutes: [Int]

    public init(useDefault: Bool = true, minutes: [Int] = []) {
        self.useDefault = useDefault
        self.minutes = minutes
    }
}

/// Google's event color palette (`colors.get`), per account.
public struct EventColor: Codable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "eventColor"
    public var account: String
    public var colorId: String
    public var background: String
}

/// A write waiting to reach Google (§18.3). Applied to the cache when queued; sent in order.
public struct PendingWrite: Codable, Equatable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "pendingWrite"

    public var id: Int64?
    public var account: String
    public var calendarId: String
    /// The event the write is about, for refetching it when the write fails.
    public var eventId: String
    public var method: String
    /// Under the Calendar API base, e.g. "/calendars/primary/events/abc"; a task write's is absolute.
    public var path: String
    public var query: [String: String]
    public var body: Data?
    public var ifMatch: String?
    /// A recurring series to refetch once the write lands (edits and deletes of a whole series).
    public var refreshSeries: String?
    /// Sent as an `events.insert` when the write fails (undo of a delete, §8.2).
    public var fallbackBody: Data?
    /// For an insert: the id of the cached placeholder it replaces, removed when Google's copy
    /// (with its new id) arrives. A move to another account caches the event under its old id.
    public var replaces: String?
    /// The event's title, for error messages.
    public var summary: String
    public var createdAt: Date

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    /// A Google Tasks write: `calendarId` is the task list and `eventId` the task.
    public var isTask: Bool { path.hasPrefix(GoogleTasksAPI.base) }

    public init(account: String, calendarId: String, eventId: String, method: String, path: String,
                query: [String: String] = [:], body: [String: Any]? = nil, ifMatch: String? = nil,
                refreshSeries: String? = nil, fallbackBody: [String: Any]? = nil, summary: String, createdAt: Date) {
        self.account = account
        self.calendarId = calendarId
        self.eventId = eventId
        self.method = method
        self.path = path
        self.query = query
        self.body = body.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        self.ifMatch = ifMatch
        self.refreshSeries = refreshSeries
        self.fallbackBody = fallbackBody.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        self.summary = summary
        self.createdAt = createdAt
    }
}

/// A person for invitee suggestions (§18.4).
public struct Contact: Codable, Equatable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "contact"
    /// The signed-in account the contact came from; empty for an attendee found in cached events.
    public var account: String
    public var email: String
    public var name: String?
    public var photoURL: String?

    public init(account: String, email: String, name: String?, photoURL: String?) {
        self.account = account
        self.email = email
        self.name = name
        self.photoURL = photoURL
    }
}

extension Array where Element == Contact {
    /// Contacts whose name or email contains `query`; names with a word starting with it come
    /// first, then emails starting with it (§5.2: "fuzzy on first/last name").
    public func matching(_ query: String, limit: Int = 8) -> [Contact] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        func rank(_ c: Contact) -> Int? {
            let name = (c.name ?? "").lowercased(), email = c.email.lowercased()
            if name.split(separator: " ").contains(where: { $0.hasPrefix(q) }) { return 0 }
            if email.hasPrefix(q) { return 1 }
            return name.contains(q) || email.contains(q) ? 2 : nil
        }
        return compactMap { c in rank(c).map { (c, $0) } }
            .sorted { ($0.1, $0.0.name ?? $0.0.email) < ($1.1, $1.0.name ?? $1.0.email) }
            .prefix(limit).map(\.0)
    }

    /// The email of the one contact whose full or first name is `name`, for `with <name>` (§5.2).
    /// nil when no contact matches or several do.
    public func uniqueEmail(named name: String) -> String? {
        let lower = name.lowercased()
        let emails = Set(filter { c in
            guard let n = c.name?.lowercased() else { return false }
            return n == lower || n.split(separator: " ").first.map(String.init) == lower
        }.map { $0.email.lowercased() })
        return emails.count == 1 ? first { $0.email.lowercased() == emails.first }?.email : nil
    }
}

/// A Google Tasks list (§10).
public struct TaskList: Codable, Equatable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "taskList"
    public var account: String
    public var id: String
    public var title: String
    /// When this list's tasks were last fetched; the next fetch asks only for changes since then.
    public var syncedAt: Date?

    public var key: String { "\(account)|\(id)" }
}

/// A Google task (§10, §18.2). Google keeps only the due date, no time.
public struct TaskItem: Codable, Equatable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "task"
    public var account: String
    public var listId: String
    public var id: String
    public var title: String
    public var notes: String?
    public var completed: Bool
    /// Local midnight of the due date.
    public var due: Date?
    public var parent: String?
    /// Google's sort key within the list ("My Order").
    public var position: String

    public var key: String { "\(account)|\(listId)|\(id)" }
    public var listKey: String { "\(account)|\(listId)" }

    public init(account: String, listId: String, id: String, title: String, notes: String? = nil, completed: Bool = false,
                due: Date? = nil, parent: String? = nil, position: String = "") {
        self.account = account
        self.listId = listId
        self.id = id
        self.title = title
        self.notes = notes
        self.completed = completed
        self.due = due
        self.parent = parent
        self.position = position
    }
}
