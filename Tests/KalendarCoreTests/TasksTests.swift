// Google Tasks (§10, §18.2): sync, the cache's agenda query, and writes through the queue.
import XCTest
@testable import KalendarCore

@MainActor
final class TasksTests: XCTestCase {
    private let google = FakeGoogle()
    private var cache: CalendarCache!
    private var engine: SyncEngine!
    private var writer: EventWriter!
    private var now = ISO8601DateFormatter().date(from: "2026-10-12T17:00:00Z")!
    private let me = "me@example.com"

    override func setUp() async throws {
        let defaults = UserDefaults(suiteName: "TasksTests")!
        defaults.removePersistentDomain(forName: "TasksTests")
        defaults.set([me, "work@example.com"], forKey: "accounts")
        let google = self.google
        let accounts = AccountStore(defaults: defaults, vault: StubVault(), transport: { try await google($0) },
                                    now: { [now] in now })
        cache = try CalendarCache()
        engine = SyncEngine(accounts: accounts, cache: cache, defaults: defaults, now: { [unowned self] in now })
        writer = EventWriter(accounts: accounts, cache: cache, engine: engine, now: { [now] in now })
    }

    private func day(_ text: String) -> Date {
        let p = text.split(separator: "-").map { Int($0)! }
        return Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))!
    }

    private func task(_ id: String, list: String = "L1", account: String? = nil, due: String? = nil,
                      completed: Bool = false) -> TaskItem {
        TaskItem(account: account ?? me, listId: list, id: id, title: "Task \(id)", completed: completed,
                 due: due.map(day), position: id)
    }

    // MARK: Sync

    func testSyncFetchesListsThenOnlyChanges() async throws {
        var updatedMins: [String?] = []
        google.handler = { request, q in
            let path = request.url!.path
            if request.url!.host == "tasks.googleapis.com" {
                if path == "/tasks/v1/users/@me/lists" {
                    return (200, #"{"items":[{"id":"L1","title":"My Tasks"}]}"#)
                }
                updatedMins.append(q["updatedMin"])
                if q["updatedMin"] == nil {
                    XCTAssertEqual(q["showHidden"], "true")
                    XCTAssertEqual(q["showCompleted"], "true")
                    return (200, #"{"items":[{"id":"a","title":"Buy milk","status":"needsAction","due":"2026-10-14T00:00:00.000Z","position":"001"},{"id":"b","title":"Old","status":"completed","position":"002","parent":"a"}]}"#)
                }
                XCTAssertEqual(q["showDeleted"], "true")
                return (200, #"{"items":[{"id":"b","deleted":true},{"id":"c","title":"New","status":"needsAction","position":"003"}]}"#)
            }
            if path.hasSuffix("/calendarList") { return (200, #"{"items":[]}"#) }
            if path.hasSuffix("/colors") { return (200, #"{"event":{}}"#) }
            return (200, #"{"items":[]}"#)
        }
        try await engine.syncTasks(account: me)
        XCTAssertEqual(try cache.taskLists().map(\.title), ["My Tasks"])
        let first = try cache.allTasks().sorted { $0.id < $1.id }
        XCTAssertEqual(first.map(\.id), ["a", "b"])
        XCTAssertEqual(first[0].due, day("2026-10-14"), "Google's midnight UTC is that calendar day, locally")
        XCTAssertTrue(first[1].completed)
        XCTAssertEqual(first[1].parent, "a")

        now = now.addingTimeInterval(600)
        try await engine.syncTasks(account: me)
        XCTAssertEqual(try cache.allTasks().map(\.id).sorted(), ["a", "c"])
        XCTAssertNil(updatedMins[0])
        XCTAssertNotNil(updatedMins[1], "the second fetch asks only for changes")
    }

    func testListGoneFromGoogleTakesItsTasks() throws {
        try cache.replaceTaskLists([TaskList(account: me, id: "L1", title: "A"), TaskList(account: me, id: "L2", title: "B")], account: me)
        try cache.upsertTask(task("x", list: "L2"))
        try cache.replaceTaskLists([TaskList(account: me, id: "L1", title: "A")], account: me)
        XCTAssertTrue(try cache.allTasks().isEmpty)
    }

    /// The agenda (§4.3): tasks due in the range, and incomplete ones due earlier.
    func testAgendaQueryIncludesOverdueIncompleteTasks() throws {
        for t in [task("due", due: "2026-10-14"), task("overdue", due: "2026-09-28"),
                  task("doneLate", due: "2026-09-28", completed: true), task("undated"), task("later", due: "2026-12-01")] {
            try cache.upsertTask(t)
        }
        let found = try cache.tasks(dueFrom: day("2026-10-12"), to: day("2026-11-12"), overdueBefore: day("2026-10-12"))
        XCTAssertEqual(found.map(\.id), ["overdue", "due"])
    }

    // MARK: Writes

    func testInsertReplacesPlaceholderAndRetargetsLaterWrites() async throws {
        var calls: [String] = []
        google.handler = { request, _ in
            calls.append("\(request.httpMethod!) \(request.url!.path)")
            if request.httpMethod == "POST" {
                XCTAssertEqual(request.json?["due"] as? String, "2026-10-14T00:00:00.000Z")
                return (200, #"{"id":"real","title":"Buy milk","status":"needsAction","due":"2026-10-14T00:00:00.000Z","position":"009"}"#)
            }
            XCTAssertEqual(request.json?["status"] as? String, "completed")
            return (200, #"{"id":"real","title":"Buy milk","status":"completed","position":"009"}"#)
        }
        google.offline = true
        writer.insertTask(title: "Buy milk", notes: nil, due: day("2026-10-14"), account: me, listId: "L1")
        await writer.flush()
        let placeholder = try XCTUnwrap(try cache.allTasks().first)
        XCTAssertTrue(placeholder.id.hasPrefix("local-"))
        // completed before the insert reached Google
        writer.setCompleted(placeholder, true)
        google.offline = false
        await writer.flush()

        XCTAssertEqual(calls, ["POST /tasks/v1/lists/L1/tasks", "PATCH /tasks/v1/lists/L1/tasks/real"])
        let tasks = try cache.allTasks()
        XCTAssertEqual(tasks.map(\.id), ["real"])
        XCTAssertTrue(tasks[0].completed)
    }

    func testUncompleteClearsCompletedDate() async throws {
        try cache.upsertTask(task("a", completed: true))
        google.handler = { request, _ in
            XCTAssertEqual(request.json?["status"] as? String, "needsAction")
            XCTAssertTrue(request.json?["completed"] is NSNull)
            return (200, #"{"id":"a","title":"Task a","status":"needsAction","position":"a"}"#)
        }
        writer.setCompleted(task("a", completed: true), false)
        XCTAssertFalse(try XCTUnwrap(cache.task(account: me, listId: "L1", id: "a")).completed, "optimistic")
        await writer.flush()
        XCTAssertEqual(google.requests.count, 1)
    }

    func testMoveWithinAccountUsesTasksMove() async throws {
        try cache.upsertTask(task("a"))
        google.handler = { request, q in
            XCTAssertEqual(request.url!.path, "/tasks/v1/lists/L1/tasks/a/move")
            XCTAssertEqual(q["destinationTasklist"], "L2")
            return (200, #"{"id":"a","title":"Task a","status":"needsAction","position":"5"}"#)
        }
        writer.move(task("a"), to: TaskList(account: me, id: "L2", title: "Errands"))
        XCTAssertEqual(try cache.allTasks().map(\.listId), ["L2"], "optimistic")
        await writer.flush()
        let moved = try cache.allTasks()
        XCTAssertEqual(moved.map(\.listId), ["L2"])
        XCTAssertEqual(moved.first?.position, "5")
    }

    func testFailedMoveRestoresTheTask() async throws {
        try cache.upsertTask(task("a"))
        google.handler = { request, _ in
            if request.url!.path.hasSuffix("/move") { return (400, "{}") }
            return (200, #"{"id":"a","title":"Task a","status":"needsAction","position":"a"}"#)
        }
        writer.move(task("a"), to: TaskList(account: me, id: "L2", title: "Errands"))
        await writer.flush()
        XCTAssertEqual(try cache.allTasks().map(\.listKey), ["\(me)|L1"])
        XCTAssertNotNil(writer.error)
    }

    /// Insert-then-delete across accounts (§7.3): a refused insert keeps the original.
    func testMoveAcrossAccountsKeepsOriginalWhenInsertFails() async throws {
        try cache.upsertTask(task("a"))
        google.handler = { request, _ in
            if request.httpMethod == "POST" { return (403, "{}") }
            if request.httpMethod == "DELETE" { XCTFail("the delete must not run"); return (204, "") }
            return (200, #"{"id":"a","title":"Task a","status":"needsAction","position":"a"}"#)
        }
        writer.move(task("a"), to: TaskList(account: "work@example.com", id: "W", title: "Work"))
        XCTAssertEqual(try cache.allTasks().map(\.account), ["work@example.com"], "optimistic")
        await writer.flush()
        XCTAssertEqual(try cache.allTasks().map(\.key), ["\(me)|L1|a"])
        XCTAssertEqual(try cache.pendingWriteCount(), 0)
    }

    func testDeleteTask() async throws {
        try cache.upsertTask(task("a"))
        google.handler = { _, _ in (204, "") }
        writer.deleteTask(task("a"))
        await writer.flush()
        XCTAssertEqual(google.requests.first?.httpMethod, "DELETE")
        XCTAssertTrue(try cache.allTasks().isEmpty)
    }
}
