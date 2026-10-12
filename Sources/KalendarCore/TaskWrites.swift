// Task writes (§5.1, §7.3, §10) through the event write queue (§18.3). A task write's `calendarId`
// is its list and `eventId` the task; its path is an absolute Tasks API URL.
import Foundation

extension EventWriter {
    /// A new task, cached at once under a placeholder id that Google's copy replaces.
    /// `movedFrom` is the task a cross-account move copies, so a failed insert also drops its delete.
    public func insertTask(title: String, notes: String?, due: Date?, completed: Bool = false,
                           account: String, listId: String, movedFrom: String? = nil) {
        let placeholder = Self.placeholderId()
        var body = GoogleTasksAPI.body(title: title, notes: notes, due: due)
        if completed { body["status"] = "completed" }
        var write = PendingWrite(account: account, calendarId: listId, eventId: movedFrom ?? placeholder, method: "POST",
                                 path: GoogleTasksAPI.taskPath(listId: listId), body: body,
                                 summary: title, createdAt: now())
        write.replaces = placeholder
        // "~" sorts after Google's numeric positions: a new task is last in My Order until it lands
        queue(write) { try $0.upsertTask(TaskItem(account: account, listId: listId, id: placeholder, title: title,
                                                  notes: notes, completed: completed, due: due, position: "~")) }
    }

    /// Complete / Uncomplete (§10).
    public func setCompleted(_ task: TaskItem, _ completed: Bool) {
        // Google sets `completed` itself when the status becomes completed; uncompleting must clear it
        var body: [String: Any] = ["status": completed ? "completed" : "needsAction"]
        if !completed { body["completed"] = NSNull() }
        var t = task
        t.completed = completed
        write(t, method: "PATCH", body: body)
    }

    /// Title, notes and due date edits.
    public func update(_ task: TaskItem) {
        write(task, method: "PATCH", body: GoogleTasksAPI.body(title: task.title, notes: task.notes, due: task.due))
    }

    public func deleteTask(_ task: TaskItem) {
        queue(taskWrite(task, method: "DELETE")) { try $0.deleteTask(account: task.account, listId: task.listId, id: task.id) }
    }

    public func canMove(_ task: TaskItem, to list: TaskList) -> Bool {
        !destinations(for: task, among: [list]).isEmpty
    }

    /// The lists `task` can move to, among `lists`: any other list. Across accounts the move
    /// deletes the original, and Google deletes a task's subtasks with it, so a task with subtasks
    /// stays in its account.
    public func destinations(for task: TaskItem, among lists: [TaskList]) -> [TaskList] {
        let staysInAccount = (try? cache.hasSubtasks(task)) ?? true
        return lists.filter { $0.key != task.listKey && (!staysInAccount || $0.account == task.account) }
    }

    /// Move to List › (§7.3): `tasks.move` within an account, insert-then-delete across accounts.
    public func move(_ task: TaskItem, to list: TaskList) {
        guard canMove(task, to: list) else { return }
        guard list.account == task.account else {
            insertTask(title: task.title, notes: task.notes, due: task.due, completed: task.completed,
                       account: list.account, listId: list.id, movedFrom: task.id)
            deleteTask(task)
            return
        }
        var moved = taskWrite(task, method: "POST", suffix: "/move", query: ["destinationTasklist": list.id])
        moved.replaces = task.id
        var t = task
        t.listId = list.id
        t.parent = nil
        queue(moved) { cache in
            try cache.deleteTask(account: task.account, listId: task.listId, id: task.id)
            try cache.upsertTask(t)
        }
    }

    private func write(_ task: TaskItem, method: String, body: [String: Any]) {
        queue(taskWrite(task, method: method, body: body)) { try $0.upsertTask(task) }
    }

    private func taskWrite(_ task: TaskItem, method: String, suffix: String = "", query: [String: String] = [:],
                           body: [String: Any]? = nil) -> PendingWrite {
        PendingWrite(account: task.account, calendarId: task.listId, eventId: task.id, method: method,
                     path: GoogleTasksAPI.taskPath(listId: task.listId, taskId: task.id) + suffix,
                     query: query, body: body, summary: task.title, createdAt: now())
    }

    /// Queues the write, applies its change to the cache so the UI shows it at once, and sends it.
    private func queue(_ write: PendingWrite, cacheChange: (CalendarCache) throws -> Void) {
        enqueue(write)
        try? cacheChange(cache)
        engine.onChange()
        Task { await flush() }
    }

    /// A task write Google accepted: its response becomes the cached task.
    func landedTask(_ write: PendingWrite, data: Data) {
        guard write.method != "DELETE",
              let g = try? JSONDecoder().decode(GoogleTasksAPI.GoogleTask.self, from: data) else { return }
        let listId = write.query["destinationTasklist"] ?? write.calendarId
        if let old = write.replaces {
            // an insert's placeholder, or a moved task's optimistic copy
            try? cache.deleteTask(account: write.account, listId: listId, id: old)
            try? cache.retargetQueued(account: write.account, calendarId: listId, from: old, to: g.id)
        }
        try? cache.upsertTask(g.task(account: write.account, listId: listId))
    }

    /// The cache's copy of a task after a rejected write: whatever Google has now.
    func refetchTask(_ write: PendingWrite) async {
        if let placeholder = write.replaces {
            // an insert's placeholder, or a moved task's optimistic copy in the destination list
            let listId = write.query["destinationTasklist"] ?? write.calendarId
            try? cache.deleteTask(account: write.account, listId: listId, id: placeholder)
            guard write.path.hasSuffix("/move") else { return }
        }
        do {
            let g = try await accounts.calendarAPI(GoogleTasksAPI.GoogleTask.self, for: write.account,
                GoogleTasksAPI.getTaskRequest(listId: write.calendarId, taskId: write.eventId))
            if g.deleted == true {
                try? cache.deleteTask(account: write.account, listId: write.calendarId, id: write.eventId)
            } else {
                try? cache.upsertTask(g.task(account: write.account, listId: write.calendarId))
            }
        } catch GoogleCalendarAPI.APIError.notFound {
            try? cache.deleteTask(account: write.account, listId: write.calendarId, id: write.eventId)
        } catch {}
    }
}
