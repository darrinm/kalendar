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

    static var migrator: DatabaseMigrator {
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
        m.registerMigration("v2-editing") { db in
            try db.alter(table: "event") { t in
                t.add(column: "etag", .text)
                t.add(column: "visibility", .text)
                t.add(column: "reminders", .text).notNull().defaults(to: #"{"useDefault":true,"minutes":[]}"#)
                t.add(column: "timeZone", .text)
            }
            try db.alter(table: "calendar") { t in
                t.add(column: "defaultReminders", .text).notNull().defaults(to: "[]")
            }
            // the new fields arrive only with a full sync
            try db.execute(sql: "UPDATE calendar SET syncToken = NULL")
            try db.create(table: "pendingWrite") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("account", .text).notNull()
                t.column("calendarId", .text).notNull()
                t.column("eventId", .text).notNull()
                t.column("method", .text).notNull()
                t.column("path", .text).notNull()
                t.column("query", .text).notNull()
                t.column("body", .blob)
                t.column("ifMatch", .text)
                t.column("refreshSeries", .text)
                t.column("fallbackBody", .blob)
                t.column("summary", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
        }
        m.registerMigration("v3-replaces") { db in
            try db.alter(table: "pendingWrite") { t in t.add(column: "replaces", .text) }
        }
        m.registerMigration("v5-tasks") { db in
            try db.create(table: "taskList") { t in
                t.column("account", .text).notNull()
                t.column("id", .text).notNull()
                t.column("title", .text).notNull()
                t.column("syncedAt", .datetime)
                t.primaryKey(["account", "id"])
            }
            try db.create(table: "task") { t in
                t.column("account", .text).notNull()
                t.column("listId", .text).notNull()
                t.column("id", .text).notNull()
                t.column("title", .text).notNull()
                t.column("notes", .text)
                t.column("completed", .boolean).notNull()
                t.column("due", .datetime)
                t.column("parent", .text)
                t.column("position", .text).notNull()
                t.primaryKey(["account", "listId", "id"])
            }
            try db.create(index: "task_due", on: "task", columns: ["due"])
        }
        m.registerMigration("v4-contacts") { db in
            try db.create(table: "contact") { t in
                t.column("account", .text).notNull()
                t.column("email", .text).notNull()
                t.column("name", .text)
                t.column("photoURL", .text)
                t.primaryKey(["account", "email"])
            }
        }
        m.registerMigration("v6-task-due-day") { db in
            // `due` held local midnight as an instant, which moves to another day when the time zone
            // changes; `dueDay` holds the calendar day. Existing rows were written in this time zone.
            try db.alter(table: "task") { t in t.add(column: "dueDay", .text) }
            try db.execute(sql: "UPDATE task SET dueDay = date(due, 'localtime') WHERE due IS NOT NULL")
            try db.drop(index: "task_due")
            try db.alter(table: "task") { t in t.drop(column: "due") }
            try db.create(index: "task_dueDay", on: "task", columns: ["dueDay"])
        }
        m.registerMigration("v7-event-by-calendar") { db in
            // deleteEvent matches an event in every account that caches its calendar, so it looks
            // up by calendar without the account the primary key and event_series start with
            try db.create(index: "event_calendar_id", on: "event", columns: ["calendarId", "id"])
            try db.create(index: "event_calendar_series", on: "event", columns: ["calendarId", "recurringEventId"])
        }
        m.registerMigration("v8-contact-alias") { db in
            try db.alter(table: "contact") { t in t.add(column: "isAlias", .boolean).notNull().defaults(to: false) }
        }
        m.registerMigration("v9-series-response") { db in
            try db.alter(table: "pendingWrite") { t in t.add(column: "response", .text) }
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
        let pattern = Self.containsPattern(text)
        // attendees is a JSON array; match only each attendee's name and email, not the JSON keys
        let invitees = "EXISTS (SELECT 1 FROM json_each(event.attendees) WHERE "
            + "json_extract(value, '$.email') LIKE :p ESCAPE '\\' "
            + "OR json_extract(value, '$.displayName') LIKE :p ESCAPE '\\')"
        let condition: String = switch scope {
        case .title: "event.summary LIKE :p ESCAPE '\\'"
        case .location: "event.location LIKE :p ESCAPE '\\'"
        case .invitees: invitees
        case .all: "(event.summary LIKE :p ESCAPE '\\' OR event.location LIKE :p ESCAPE '\\' "
            + "OR event.notes LIKE :p ESCAPE '\\' OR \(invitees))"
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

    /// A `LIKE … ESCAPE '\\'` pattern matching any text that contains `text` literally.
    static func containsPattern(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
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
    /// Calendars no longer listed are deleted with their events. Returns whether anything changed.
    @discardableResult
    public func replaceCalendars(_ list: [CalendarInfo], account: String) throws -> Bool {
        try db.write { db in
            let existing = Dictionary(uniqueKeysWithValues:
                try CalendarInfo.filter(Column("account") == account).fetchAll(db).map { ($0.id, $0) })
            let ids = Set(list.map(\.id))
            for gone in existing.keys where !ids.contains(gone) {
                try EventInstance.filter(Column("account") == account && Column("calendarId") == gone).deleteAll(db)
                try CalendarInfo.deleteOne(db, key: ["account": account, "id": gone])
            }
            var changed = existing.count != list.count
            for var c in list {
                if let old = existing[c.id] {
                    c.syncToken = old.syncToken
                    c.windowStart = old.windowStart
                    c.windowEnd = old.windowEnd
                }
                if existing[c.id] != c {
                    try c.save(db)
                    changed = true
                }
            }
            return changed
        }
    }

    public func saveCalendar(_ calendar: CalendarInfo) throws {
        try db.write { try calendar.save($0) }
    }

    /// Changes only the calendar's visibility, leaving its sync state as the sync engine last wrote it.
    public func setSelected(_ selected: Bool, account: String, calendarId: String) throws {
        try db.write { db in
            _ = try CalendarInfo.filter(Column("account") == account && Column("id") == calendarId)
                .updateAll(db, Column("selected").set(to: selected))
        }
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
            // insert, not save: the rows were just deleted, so save's UPDATE attempt would be wasted
            for e in events { try e.insert(db, onConflict: .replace) }
        }
    }

    /// Incremental sync: upserts, deletions by id, and replaced recurring series.
    public func applyChanges(account: String, calendarId: String, upserts: [EventInstance],
                             deletedIds: Set<String>, replacedSeries: [String: [EventInstance]]) throws {
        try db.write { db in
            let calendarRows = EventInstance.filter(Column("account") == account && Column("calendarId") == calendarId)
            // a deleted recurring master arrives as a bare cancelled id, so its instances go too
            if !deletedIds.isEmpty {
                try calendarRows.filter(deletedIds.contains(Column("id")) || deletedIds.contains(Column("recurringEventId")))
                    .deleteAll(db)
            }
            for (series, instances) in replacedSeries {
                try calendarRows.filter(Column("recurringEventId") == series || Column("id") == series).deleteAll(db)
                for e in instances { try e.save(db) }
            }
            for e in upserts { try e.save(db) }
        }
    }

    // MARK: Edits (milestone 3)

    /// Every cached instance on one calendar, shown or hidden.
    public func events(account: String, calendarId: String) throws -> [EventInstance] {
        try db.read { try EventInstance.filter(Column("account") == account && Column("calendarId") == calendarId).fetchAll($0) }
    }

    public func event(account: String, calendarId: String, id: String) throws -> EventInstance? {
        try db.read { try EventInstance.fetchOne($0, key: ["account": account, "calendarId": calendarId, "id": id]) }
    }

    /// The other accounts' cached copies of an event, when they cache its calendar too.
    public func copies(calendarId: String, id: String, except account: String) throws -> [EventInstance] {
        try db.read { db in
            try EventInstance.filter(Column("calendarId") == calendarId && Column("id") == id && Column("account") != account)
                .fetchAll(db)
        }
    }

    /// Every cached occurrence of `series` on one calendar.
    public func occurrences(of series: String, account: String, calendarId: String) throws -> [EventInstance] {
        try db.read { try Self.series(series, account: account, calendarId: calendarId).fetchAll($0) }
    }

    /// Whether an occurrence of `event`'s series other than `event`, ending after `now`, awaits the
    /// user's reply. False for a one-off event.
    public func otherOccurrenceAwaitsReply(_ event: EventInstance, now: Date) throws -> Bool {
        guard let series = event.recurringEventId else { return false }
        return try occurrences(of: series, account: event.account, calendarId: event.calendarId)
            .contains { $0.id != event.id && $0.end > now && $0.isUnanswered }
    }

    private static func series(_ series: String, account: String, calendarId: String) -> QueryInterfaceRequest<EventInstance> {
        EventInstance.filter(Column("account") == account && Column("calendarId") == calendarId
                             && Column("recurringEventId") == series)
    }

    /// The cached occurrence of `series` just before or after `event` (§7.1).
    public func occurrence(after event: EventInstance, in series: String, forward: Bool) throws -> EventInstance? {
        try db.read { db in
            let rows = Self.series(series, account: event.account, calendarId: event.calendarId)
            return forward
                ? try rows.filter(Column("start") > event.start).order(Column("start")).fetchOne(db)
                : try rows.filter(Column("start") < event.start).order(Column("start").desc).fetchOne(db)
        }
    }

    public func upsert(_ events: [EventInstance]) throws {
        try db.write { db in for e in events { try e.save(db) } }
    }

    /// Removes one occurrence, or with `series` every cached instance of that recurring series.
    /// Without `account`, every account that caches the calendar loses its copy: an event id names
    /// the same Google event in all of them, and a copy left behind would show until that account's
    /// next sync. With `account`, only that account's copy goes.
    public func deleteEvent(account: String? = nil, calendarId: String, id: String, series: String? = nil) throws {
        try db.write { db in
            var rows = EventInstance.filter(Column("calendarId") == calendarId)
            if let account { rows = rows.filter(Column("account") == account) }
            if let series {
                try rows.filter(Column("recurringEventId") == series || Column("id") == series).deleteAll(db)
            } else {
                try rows.filter(Column("id") == id).deleteAll(db)
            }
        }
    }

    /// Invitations awaiting the user's reply (§6.2): visible calendars the account can write, today
    /// −7 days … +90 days, not organized by the user; for a series, only its next pending occurrence.
    /// On a calendar shared read-only (another account's calendar, a colleague's), Google marks that
    /// calendar's owner as `self` and refuses a reply.
    public func pendingInvitations(now: Date) throws -> [EventInstance] {
        let from = now.addingTimeInterval(-7 * 86400), to = now.addingTimeInterval(90 * 86400)
        let rows = try db.read { db in
            try EventInstance.fetchAll(db, sql: """
                SELECT event.* FROM event JOIN calendar
                  ON calendar.account = event.account AND calendar.id = event.calendarId
                WHERE calendar.selected AND calendar.accessRole IN ('owner', 'writer')  -- CalendarInfo.isWritable
                  AND event.selfResponse = 'needsAction' AND NOT event.organizerSelf
                  AND event.end > ? AND event.start < ?
                ORDER BY event.start
                """, arguments: [from, to])
        }
        var seen = Set<String>()
        return rows.filter { seen.insert("\($0.account)|\($0.recurringEventId ?? $0.id)").inserted }
    }

    // MARK: Contacts (§18.4)

    public func replaceContacts(_ contacts: [Contact], account: String) throws {
        try db.write { db in
            try Contact.filter(Column("account") == account).deleteAll(db)
            for c in contacts { try c.insert(db, onConflict: .replace) }
        }
    }

    /// Everyone suggestions can offer (§5.1, §18.4): contacts from both accounts, then attendees of
    /// cached events, each email once. The new-item form loads this once per entry and filters it in
    /// memory as the user types.
    public func allContacts() throws -> [Contact] {
        try db.read { db in
            let saved = try Contact.fetchAll(db)
            let attendees = try Row.fetchAll(db, sql: """
                SELECT DISTINCT json_extract(value, '$.email') AS email, json_extract(value, '$.displayName') AS name
                FROM event, json_each(event.attendees)
                WHERE NOT json_extract(value, '$.isSelf')
                """).map { Contact(account: "", email: $0["email"], name: $0["name"], photoURL: nil) }
            // an alias address is left out wherever it came from: another account's contacts, an attendee
            var seen = Set(saved.filter(\.isAlias).map { $0.email.lowercased() })
            return (saved + attendees).filter { seen.insert($0.email.lowercased()).inserted }
        }
    }

    /// Locations of past events that contain `query`, most recent first (§5.2: "previous
    /// locations first").
    public func recentLocations(matching query: String, limit: Int = 3) throws -> [String] {
        let like = Self.containsPattern(query)
        return try db.read { db in
            try String.fetchAll(db, sql: """
                SELECT location FROM event WHERE location LIKE ? ESCAPE '\\' AND location NOT LIKE 'http%'
                GROUP BY location ORDER BY MAX(start) DESC LIMIT ?
                """, arguments: [like, limit])
        }
    }

    // MARK: Tasks (§10)

    /// In Google's order within each account, so the default list (§2) comes first: rows are saved
    /// as `tasklists.list` returns them and keep their row when updated.
    public func taskLists() throws -> [TaskList] {
        try db.read { try TaskList.order(Column("account"), Column.rowID).fetchAll($0) }
    }

    /// Replaces the account's lists, keeping each surviving list's sync time; a list gone from
    /// Google goes with its tasks. Returns the lists as saved.
    @discardableResult
    public func replaceTaskLists(_ lists: [TaskList], account: String) throws -> [TaskList] {
        try db.write { db in
            let existing = Dictionary(uniqueKeysWithValues:
                try TaskList.filter(Column("account") == account).fetchAll(db).map { ($0.id, $0) })
            let ids = Set(lists.map(\.id))
            for gone in existing.keys where !ids.contains(gone) {
                try TaskItem.filter(Column("account") == account && Column("listId") == gone).deleteAll(db)
                _ = try TaskList.deleteOne(db, key: ["account": account, "id": gone])
            }
            return try lists.map { l in
                var l = l
                l.syncedAt = existing[l.id]?.syncedAt
                try l.save(db)
                return l
            }
        }
    }

    public func saveTaskList(_ list: TaskList) throws {
        try db.write { try list.save($0) }
    }

    /// Changes from Google: upserts, and deletions by id. A task id is unique within the account, so
    /// an upserted task cached on another list was moved here and its old row goes.
    public func applyTaskChanges(account: String, listId: String, upserts: [TaskItem], deletedIds: Set<String>) throws {
        try db.write { db in
            if !deletedIds.isEmpty {
                try TaskItem.filter(Column("account") == account && Column("listId") == listId
                                    && deletedIds.contains(Column("id"))).deleteAll(db)
            }
            if !upserts.isEmpty {
                try TaskItem.filter(Column("account") == account && Column("listId") != listId
                                    && upserts.map(\.id).contains(Column("id"))).deleteAll(db)
            }
            for t in upserts { try t.save(db) }
        }
    }

    public func task(account: String, listId: String, id: String) throws -> TaskItem? {
        try db.read { try TaskItem.fetchOne($0, key: ["account": account, "listId": listId, "id": id]) }
    }

    public func hasSubtasks(_ task: TaskItem) throws -> Bool {
        try db.read { db in
            try TaskItem.filter(Column("account") == task.account && Column("listId") == task.listId
                                && Column("parent") == task.id).fetchCount(db) > 0
        }
    }

    public func upsertTask(_ task: TaskItem) throws { try db.write { try task.save($0) } }

    public func deleteTask(account: String, listId: String, id: String) throws {
        try db.write { _ = try TaskItem.deleteOne($0, key: ["account": account, "listId": listId, "id": id]) }
    }

    /// Every task, for the Tasks view (§10).
    public func allTasks() throws -> [TaskItem] {
        try db.read { try TaskItem.fetchAll($0) }
    }

    /// Tasks due in [from, to), and incomplete ones due before `from` (shown as overdue today, §4.3).
    /// The days are compared as "YYYY-MM-DD", in the current time zone.
    public func tasks(dueFrom from: Date, to: Date, overdueBefore today: Date) throws -> [TaskItem] {
        let day = { GoogleCalendarAPI.ymd($0, calendar: .current) }
        let (from, to, today) = (day(from), day(to), day(today))
        return try db.read { db in
            try TaskItem.filter(Column("dueDay") != nil && ((Column("dueDay") >= from && Column("dueDay") < to)
                                || (Column("dueDay") < today && Column("completed") == false)))
                .order(Column("dueDay")).fetchAll(db)
        }
    }

    // MARK: Write queue (§18.3)

    public func enqueue(_ write: PendingWrite) throws {
        try db.write { db in
            var w = write
            try w.insert(db)
        }
    }

    public func nextWrite() throws -> PendingWrite? {
        try db.read { try PendingWrite.order(Column("id")).fetchOne($0) }
    }

    public func removeWrite(_ id: Int64) throws {
        try db.write { _ = try PendingWrite.deleteOne($0, key: id) }
    }

    /// Removes every queued write about `eventId` and returns them.
    public func removeWrites(eventId: String) throws -> [PendingWrite] {
        try db.write { db in
            let rows = PendingWrite.filter(Column("eventId") == eventId)
            let removed = try rows.fetchAll(db)
            try rows.deleteAll(db)
            return removed
        }
    }

    /// Points queued writes about `eventId` at the event's new version.
    public func updateQueuedIfMatch(eventId: String, to etag: String) throws {
        try db.write { db in
            _ = try PendingWrite.filter(Column("eventId") == eventId && Column("ifMatch") != nil)
                .updateAll(db, Column("ifMatch").set(to: etag))
        }
    }

    /// An insert landed: writes queued against the item it replaced on that calendar or list now go
    /// to Google's id. (A cross-account move's delete of the original is on the other account.)
    public func retargetQueued(account: String, calendarId: String, from placeholder: String, to id: String) throws {
        guard placeholder != id else { return }
        try db.write { db in
            for var w in try PendingWrite.filter(Column("account") == account && Column("calendarId") == calendarId
                                                 && Column("eventId") == placeholder).fetchAll(db) {
                w.eventId = id
                w.path = w.path.replacingOccurrences(of: placeholder, with: id)
                try w.update(db)
            }
        }
    }

    public func pendingWriteCount() throws -> Int {
        try db.read { try PendingWrite.fetchCount($0) }
    }

    /// Sign-out (§8.5): everything cached for the account.
    public func deleteAccount(_ account: String) throws {
        try db.write { db in
            try EventInstance.filter(Column("account") == account).deleteAll(db)
            try CalendarInfo.filter(Column("account") == account).deleteAll(db)
            try EventColor.filter(Column("account") == account).deleteAll(db)
            try PendingWrite.filter(Column("account") == account).deleteAll(db)
            try Contact.filter(Column("account") == account).deleteAll(db)
            try TaskItem.filter(Column("account") == account).deleteAll(db)
            try TaskList.filter(Column("account") == account).deleteAll(db)
        }
    }
}
