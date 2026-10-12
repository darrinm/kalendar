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
        enqueue(write)
        // "~" sorts after Google's numeric positions: a new task is last in My Order until it lands
        try? cache.upsertTask(TaskItem(account: account, listId: listId, id: placeholder, title: title, notes: notes,
                                       completed: completed, due: due, position: "~"))
        engine.onChange()
        Task { await flush() }
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
        enqueue(PendingWrite(account: task.account, calendarId: task.listId, eventId: task.id, method: "DELETE",
                             path: GoogleTasksAPI.taskPath(listId: task.listId, taskId: task.id),
                             summary: task.title, createdAt: now()))
        try? cache.deleteTask(account: task.account, listId: task.listId, id: task.id)
        engine.onChange()
        Task { await flush() }
    }

    /// Whether `list` can take `task`. Across accounts the move deletes the original, and Google
    /// deletes a task's subtasks with it, so a task with subtasks stays in its account.
    public func canMove(_ task: TaskItem, to list: TaskList) -> Bool {
        list.account == task.account || !((try? cache.hasSubtasks(task)) ?? true)
    }

    /// Move to List › (§7.3): `tasks.move` within an account, insert-then-delete across accounts.
    public func move(_ task: TaskItem, to list: TaskList) {
        guard list.account != task.account || list.id != task.listId, canMove(task, to: list) else { return }
        guard list.account == task.account else {
            insertTask(title: task.title, notes: task.notes, due: task.due, completed: task.completed,
                       account: list.account, listId: list.id, movedFrom: task.id)
            deleteTask(task)
            return
        }
        var moved = PendingWrite(account: task.account, calendarId: task.listId, eventId: task.id, method: "POST",
                                 path: GoogleTasksAPI.taskPath(listId: task.listId, taskId: task.id) + "/move",
                                 query: ["destinationTasklist": list.id], summary: task.title, createdAt: now())
        moved.replaces = task.id
        enqueue(moved)
        try? cache.deleteTask(account: task.account, listId: task.listId, id: task.id)
        var t = task
        t.listId = list.id
        t.parent = nil
        try? cache.upsertTask(t)
        engine.onChange()
        Task { await flush() }
    }

    private func write(_ task: TaskItem, method: String, body: [String: Any]) {
        enqueue(PendingWrite(account: task.account, calendarId: task.listId, eventId: task.id, method: method,
                             path: GoogleTasksAPI.taskPath(listId: task.listId, taskId: task.id),
                             body: body, summary: task.title, createdAt: now()))
        try? cache.upsertTask(task)
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
            if Self.isPlaceholder(old) { try? cache.retargetQueued(from: old, to: g.id) }
        }
        try? cache.upsertTask(g.task(account: write.account, listId: listId))
    }

    /// The cache's copy of a task after a rejected write: whatever Google has now.
    func refetchTask(_ write: PendingWrite) async {
        if let placeholder = write.replaces {
            // an insert's placeholder, or a moved task's optimistic copy in the destination list
            try? cache.deleteTask(account: write.account, listId: write.query["destinationTasklist"] ?? write.calendarId,
                                  id: placeholder)
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
