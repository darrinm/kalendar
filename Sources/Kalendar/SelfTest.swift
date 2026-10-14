// `-selfTest <file>`: runs the write paths against Google with the signed-in accounts, checks
// Google's copy after each step, cleans up, writes a report to <file>, and quits. Events go only to
// a calendar named "test"; tasks are a throwaway task in the account's first list. One test
// notification is delivered.
import AppKit
import KalendarCore
import UserNotifications

@MainActor
struct SelfTest {
    let accounts: AccountStore
    let cache: CalendarCache
    let engine: SyncEngine
    let writer: EventWriter
    private var lines: [String] = []
    /// Titles of everything the self-test creates; cleanUpLeftovers() deletes whatever has them.
    private static let eventPrefix = "Kalendar self-test "
    private static let taskPrefix = "Kalendar self-test task "
    private var failures = 0

    init(accounts: AccountStore, cache: CalendarCache, engine: SyncEngine, writer: EventWriter) {
        self.accounts = accounts
        self.cache = cache
        self.engine = engine
        self.writer = writer
    }

    private mutating func check(_ ok: Bool, _ what: String) {
        lines.append((ok ? "PASS " : "FAIL ") + what)
        if !ok { failures += 1 }
    }

    private mutating func note(_ what: String) { lines.append("     " + what) }

    /// Google's copy of an event or task as JSON, with the HTTP status.
    private func google(_ account: String, _ request: GoogleCalendarAPI.Builder) async -> (Int, [String: Any]) {
        guard let (data, status) = try? await accounts.sendAuthorized(for: account, request) else { return (0, [:]) }
        return (status, (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
    }

    private func googleEvent(_ account: String, _ calendarId: String, _ id: String) async -> (Int, [String: Any]) {
        await google(account, GoogleCalendarAPI.getEventRequest(calendarId: calendarId, eventId: id))
    }

    private func googleTask(_ account: String, _ listId: String, _ id: String) async -> (Int, [String: Any]) {
        await google(account, GoogleTasksAPI.getTaskRequest(listId: listId, taskId: id))
    }

    mutating func run(reportTo path: String) async {
        await engine.syncAll()
        await events()
        await tasks()
        await cleanUpLeftovers()
        await notification()
        lines.append(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: Events (§5.4, §6, §8.2) on the "test" calendar

    private var testCalendars: [CalendarInfo] {
        (try? cache.calendars().filter { $0.summary == "test" && $0.isWritable }) ?? []
    }

    private mutating func events() async {
        guard let calendar = testCalendars.first else {
            check(false, "a writable calendar named \"test\" exists")
            return
        }
        let title = Self.eventPrefix + "\(Int(Date().timeIntervalSince1970))"
        var parsed = NLParser(defaultDuration: 1800).parse("\(title) tomorrow 7am")
        parsed.title = title
        var draft = EventDraft(parsed: parsed, account: calendar.account, calendarId: calendar.id)
        draft.addGoogleMeet = true
        writer.insert(draft)
        await writer.flush()
        guard let created = try? cache.events(account: calendar.account, calendarId: calendar.id).first(where: { $0.summary == title }) else {
            check(false, "insert: Google's copy replaces the placeholder in the cache")
            return
        }
        // the edit and delete below would queue writes against a placeholder Google never created
        guard !created.id.hasPrefix("local-") else {
            check(false, "insert: cached under Google's id")
            return
        }
        var (status, g) = await googleEvent(calendar.account, calendar.id, created.id)
        check(status == 200 && g["summary"] as? String == title, "insert: Google has the event")
        check((g["hangoutLink"] as? String)?.hasPrefix("https://meet.google.com/") == true,
              "insert: Google created a Meet link (\(g["hangoutLink"] as? String ?? "none"))")
        check(created.conferenceURL != nil || ((try? cache.event(account: calendar.account, calendarId: calendar.id,
                                                                  id: created.id))??.conferenceURL) != nil,
              "insert: the cached event has the Meet link")

        let original = EventDraft(created, recurrence: nil)
        var edited = original
        edited.summary = title + " (edited)"
        edited.location = "Kalendar test location"
        writer.clearError()
        writer.save(created, original: original, draft: edited, scope: .occurrence, series: nil)
        await writer.flush()
        (status, g) = await googleEvent(calendar.account, calendar.id, created.id)
        check(g["summary"] as? String == edited.summary && g["location"] as? String == edited.location,
              "edit: Google has the new title and location")
        check(writer.error == nil, "edit: no write error (\(writer.error ?? "none"))")

        let current = (try? cache.event(account: calendar.account, calendarId: calendar.id, id: created.id)) ?? created
        writer.delete(current, scope: .occurrence)
        await writer.flush()
        (status, g) = await googleEvent(calendar.account, calendar.id, created.id)
        check(status == 410 || status == 404 || g["status"] as? String == "cancelled", "delete: Google cancelled the event (HTTP \(status))")
        check((try? cache.event(account: calendar.account, calendarId: calendar.id, id: created.id)) == nil, "delete: gone from the cache")

        writer.undoDelete()
        await writer.flush()
        (status, g) = await googleEvent(calendar.account, calendar.id, created.id)
        let restoredInPlace = status == 200 && g["status"] as? String == "confirmed"
        note("undo: PATCH status=confirmed on the deleted event → HTTP \(status), status \(g["status"] as? String ?? "-")")
        let copy = try? cache.events(account: calendar.account, calendarId: calendar.id).first { $0.summary == edited.summary }
        check(copy != nil, "undo: the event is back in the cache" + (restoredInPlace ? " (restored in place)" : " (as an inserted copy)"))
        // cleanUpLeftovers() deletes what undo restored
    }

    // MARK: Tasks (§7.3, §10)

    private mutating func tasks() async {
        let lists = (try? cache.taskLists()) ?? []
        guard let list = lists.first else {
            check(false, "a task list exists")
            return
        }
        let title = Self.taskPrefix + "\(Int(Date().timeIntervalSince1970))"
        let due = Calendar.current.startOfDay(for: Date())
        writer.insertTask(title: title, notes: "made by -selfTest", due: due, account: list.account, listId: list.id)
        await writer.flush()
        guard var task = try? cache.allTasks().first(where: { $0.title == title }), !task.id.hasPrefix("local-") else {
            check(false, "task insert: Google's copy replaces the placeholder")
            return
        }
        var (status, g) = await googleTask(task.account, task.listId, task.id)
        check(status == 200 && (g["due"] as? String)?.hasPrefix(GoogleTasksAPI.due(due).prefix(10)) == true,
              "task insert: Google has it, due \(g["due"] as? String ?? "-")")

        writer.setCompleted(task, true)
        await writer.flush()
        (status, g) = await googleTask(task.account, task.listId, task.id)
        check(g["status"] as? String == "completed", "complete: Google status completed")
        task.completed = true
        writer.setCompleted(task, false)
        await writer.flush()
        (status, g) = await googleTask(task.account, task.listId, task.id)
        check(g["status"] as? String == "needsAction" && g["completed"] == nil, "uncomplete: needsAction, completed date cleared")
        task.completed = false

        if let other = lists.first(where: { $0.account == list.account && $0.id != list.id }) {
            writer.move(task, to: other)
            await writer.flush()
            // Google gives a task moved to another list a new id; the cache follows it
            guard let moved = try? cache.allTasks().first(where: { $0.title == title }) else {
                check(false, "move: the task is still cached")
                return
            }
            note("move: id \(task.id) → \(moved.id)")
            (status, g) = await googleTask(moved.account, other.id, moved.id)
            check(moved.listId == other.id && status == 200 && g["deleted"] as? Bool != true,
                  "move: the task is in \"\(other.title)\"")
            task = moved
        } else {
            note("move: skipped, the account has one list")
        }

        writer.clearError()
        writer.deleteTask(task)
        await writer.flush()
        (status, g) = await googleTask(task.account, task.listId, task.id)
        check(status == 404 || g["deleted"] as? Bool == true,
              "task delete: Google deleted it (HTTP \(status), write error \(writer.error ?? "none"))")
        check((try? cache.allTasks().contains { $0.title == title }) == false, "task delete: gone from the cache")
    }

    /// Deletes the self-test events and tasks still cached: the event undo restored, and anything a
    /// failed step of this or an earlier run left behind.
    private mutating func cleanUpLeftovers() async {
        let events = (try? testCalendars.flatMap { try cache.events(account: $0.account, calendarId: $0.id) }
            .filter { $0.summary.hasPrefix(Self.eventPrefix) }) ?? []
        let tasks = (try? cache.allTasks().filter { $0.title.hasPrefix(Self.taskPrefix) }) ?? []
        for old in events { writer.delete(old, scope: .occurrence) }
        for old in tasks { writer.deleteTask(old) }
        await writer.flush()
        for old in events {
            let (s, j) = await googleEvent(old.account, old.calendarId, old.id)
            check(s == 404 || s == 410 || j["status"] as? String == "cancelled", "cleanup: deleted \"\(old.summary)\" (HTTP \(s))")
        }
        for old in tasks {
            let (s, j) = await googleTask(old.account, old.listId, old.id)
            check(s == 404 || j["deleted"] as? Bool == true, "cleanup: deleted \"\(old.title)\" (HTTP \(s))")
        }
    }

    // MARK: Alerts (§19)

    private mutating func notification() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        // provisional authorization delivers quietly to Notification Center, which is what this checks
        let allowed = [.authorized, .provisional].contains(settings.authorizationStatus)
        check(allowed, "notifications are authorized")
        guard allowed else { return }
        let start = Date().addingTimeInterval(600)
        var e = EventInstance(placeholder: "self-test", draft: EventDraft(
            parsed: NLParser().parse("Kalendar self-test alert"), account: "", calendarId: "test"))
        e.summary = "Kalendar self-test alert"
        e.start = start
        e.end = start.addingTimeInterval(1800)
        e.allDay = false
        e.location = "Zoom"
        let content = AlertScheduler.content(for: e)
        // the snooze prefix keeps the reschedule that follows the writes above from removing it
        let id = AlertScheduler.snoozePrefix + "selftest|\(UUID().uuidString)"
        do {
            try await center.add(UNNotificationRequest(identifier: id, content: content,
                                                       trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)))
        } catch {
            note("alert: add failed: \(error.localizedDescription)")
        }
        var delivered: UNNotification?
        for _ in 0..<10 where delivered == nil {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            delivered = await center.deliveredNotifications().first { $0.request.identifier == id }
        }
        let pending = await center.pendingNotificationRequests().contains { $0.identifier == id }
        note("alert settings: alert \(settings.alertSetting.rawValue), style \(settings.alertStyle.rawValue), "
             + "notification center \(settings.notificationCenterSetting.rawValue); still pending: \(pending)")
        check(delivered != nil, "alert delivered: \"\(content.title)\" / \"\(content.body)\"")
        center.removeDeliveredNotifications(withIdentifiers: [id])
        // an undelivered one would fire later
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }
}
