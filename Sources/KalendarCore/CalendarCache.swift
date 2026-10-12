// The local cache (§18.3): what the UI reads, what sync writes. SQLite through GRDB.
import Foundation
import GRDB

public final class CalendarCache: @unchecked Sendable {
    private let db: DatabaseQueue

    /// `path` nil opens an in-memory database (tests).
    public init(path: String? = nil) throws {
        if let path {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            db = try DatabaseQueue(path: path)
        } else {
            db = try DatabaseQueue()
        }
        try Self.migrator.migrate(db)
    }

    /// ~/Library/Application Support/Kalendar/cache.sqlite
    public static var defaultPath: String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Kalendar/cache.sqlite").path
    }

    private static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "calendar") { t in
                t.column("account", .text).notNull()
                t.column("id", .text).notNull()
                t.column("summary", .text).notNull()
                t.column("backgroundColor", .text).notNull()
                t.column("accessRole", .text).notNull()
                t.column("selected", .boolean).notNull()
                t.column("primary", .boolean).notNull()
                t.column("syncToken", .text)
                t.column("windowStart", .datetime)
                t.column("windowEnd", .datetime)
                t.primaryKey(["account", "id"])
            }
            try db.create(table: "event") { t in
                t.column("account", .text).notNull()
                t.column("calendarId", .text).notNull()
                t.column("id", .text).notNull()
                t.column("recurringEventId", .text)
                t.column("summary", .text).notNull()
                t.column("location", .text)
                t.column("notes", .text)
                t.column("start", .datetime).notNull()
                t.column("end", .datetime).notNull()
                t.column("allDay", .boolean).notNull()
                t.column("transparency", .text)
                t.column("colorId", .text)
                t.column("conferenceURL", .text)
                t.column("selfResponse", .text)
                t.column("organizerSelf", .boolean).notNull()
                t.column("attendees", .text).notNull()
                t.column("htmlLink", .text)
                t.primaryKey(["account", "calendarId", "id"])
            }
            try db.create(index: "event_start", on: "event", columns: ["start"])
            try db.create(index: "event_series", on: "event", columns: ["account", "calendarId", "recurringEventId"])
            try db.create(table: "eventColor") { t in
                t.column("account", .text).notNull()
                t.column("colorId", .text).notNull()
                t.column("background", .text).notNull()
                t.primaryKey(["account", "colorId"])
            }
        }
        return m
    }

    // MARK: Reads

    public func calendars() throws -> [CalendarInfo] {
        try db.read { try CalendarInfo.order(Column("account"), Column("primary").desc, Column("summary")).fetchAll($0) }
    }

    public func calendars(account: String) throws -> [CalendarInfo] {
        try db.read { try CalendarInfo.filter(Column("account") == account).fetchAll($0) }
    }

    /// Instances overlapping [from, to) on selected calendars, by start.
    public func events(from: Date, to: Date) throws -> [EventInstance] {
        try db.read { db in
            try EventInstance.fetchAll(db, sql: """
                SELECT event.* FROM event JOIN calendar
                  ON calendar.account = event.account AND calendar.id = event.calendarId
                WHERE calendar.selected AND event.start < ? AND event.end > ?
                ORDER BY event.start, event.summary
                """, arguments: [to, from])
        }
    }

    public enum SearchScope: String, CaseIterable, Sendable {
        case title = "Title", location = "Location", invitees = "Invitees", all = "All"
    }

    /// Case-insensitive substring search over selected calendars (§9). `All` is title, location,
    /// notes and attendee names and emails.
    public func search(_ text: String, scope: SearchScope) throws -> [EventInstance] {
        let pattern = "%\(text.replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_"))%"
        let condition: String = switch scope {
        case .title: "event.summary LIKE :p ESCAPE '\\'"
        case .location: "event.location LIKE :p ESCAPE '\\'"
        case .invitees: "event.attendees LIKE :p ESCAPE '\\'"
        case .all: "(event.summary LIKE :p ESCAPE '\\' OR event.location LIKE :p ESCAPE '\\' "
            + "OR event.notes LIKE :p ESCAPE '\\' OR event.attendees LIKE :p ESCAPE '\\')"
        }
        return try db.read { db in
            try EventInstance.fetchAll(db, sql: """
                SELECT event.* FROM event JOIN calendar
                  ON calendar.account = event.account AND calendar.id = event.calendarId
                WHERE calendar.selected AND \(condition)
                ORDER BY event.start LIMIT 500
                """, arguments: ["p": pattern])
        }
    }

    /// colorId → "#rrggbb" for each account.
    public func eventColors() throws -> [String: [String: String]] {
        try db.read { db in
            Dictionary(grouping: try EventColor.fetchAll(db), by: \.account)
                .mapValues { Dictionary(uniqueKeysWithValues: $0.map { ($0.colorId, $0.background) }) }
        }
    }

    public func hasEventColors(account: String) throws -> Bool {
        try db.read { try EventColor.filter(Column("account") == account).fetchCount($0) > 0 }
    }

    // MARK: Writes

    /// Replaces the account's calendar list, keeping each surviving calendar's sync state.
    /// Calendars no longer listed are deleted with their events.
    public func replaceCalendars(_ list: [CalendarInfo], account: String) throws {
        try db.write { db in
            let existing = Dictionary(uniqueKeysWithValues:
                try CalendarInfo.filter(Column("account") == account).fetchAll(db).map { ($0.id, $0) })
            let ids = Set(list.map(\.id))
            for gone in existing.keys where !ids.contains(gone) {
                try EventInstance.filter(Column("account") == account && Column("calendarId") == gone).deleteAll(db)
                try CalendarInfo.deleteOne(db, key: ["account": account, "id": gone])
            }
            for var c in list {
                if let old = existing[c.id] {
                    c.syncToken = old.syncToken
                    c.windowStart = old.windowStart
                    c.windowEnd = old.windowEnd
                }
                try c.save(db)
            }
        }
    }

    public func saveCalendar(_ calendar: CalendarInfo) throws {
        try db.write { try calendar.save($0) }
    }

    public func replaceEventColors(_ colors: [EventColor], account: String) throws {
        try db.write { db in
            try EventColor.filter(Column("account") == account).deleteAll(db)
            for c in colors { try c.insert(db) }
        }
    }

    /// Full sync: the calendar's cached instances become exactly `events`.
    public func replaceEvents(_ events: [EventInstance], account: String, calendarId: String) throws {
        try db.write { db in
            try EventInstance.filter(Column("account") == account && Column("calendarId") == calendarId).deleteAll(db)
            for e in events { try e.save(db) }
        }
    }

    /// Incremental sync: upserts, deletions by id, and replaced recurring series.
    public func applyChanges(account: String, calendarId: String, upserts: [EventInstance],
                             deletedIds: Set<String>, replacedSeries: [String: [EventInstance]]) throws {
        try db.write { db in
            let calendarRows = EventInstance.filter(Column("account") == account && Column("calendarId") == calendarId)
            if !deletedIds.isEmpty { try calendarRows.filter(deletedIds.contains(Column("id"))).deleteAll(db) }
            for (series, instances) in replacedSeries {
                try calendarRows.filter(Column("recurringEventId") == series || Column("id") == series).deleteAll(db)
                for e in instances { try e.save(db) }
            }
            for e in upserts { try e.save(db) }
        }
    }

    /// Sign-out (§8.5): everything cached for the account.
    public func deleteAccount(_ account: String) throws {
        try db.write { db in
            try EventInstance.filter(Column("account") == account).deleteAll(db)
            try CalendarInfo.filter(Column("account") == account).deleteAll(db)
            try EventColor.filter(Column("account") == account).deleteAll(db)
        }
    }
}
