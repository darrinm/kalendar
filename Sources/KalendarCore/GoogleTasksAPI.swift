// Tasks API v1 (§10, §18.2). Google keeps a task's due date only: `due` arrives as midnight UTC.
import Foundation

public enum GoogleTasksAPI {
    public static let base = "https://tasks.googleapis.com/tasks/v1"

    /// A list's tasks, or one task, as an absolute URL path for the write queue.
    public static func taskPath(listId: String, taskId: String? = nil) -> String {
        base + "/lists/\(GoogleCalendarAPI.pathSegment(listId))/tasks" + (taskId.map { "/\(GoogleCalendarAPI.pathSegment($0))" } ?? "")
    }

    public static func listsRequest(pageToken: String?) -> GoogleCalendarAPI.Builder {
        { GoogleCalendarAPI.request(base + "/users/@me/lists", ["maxResults": "100", "pageToken": pageToken], accessToken: $0) }
    }

    /// Changes since `updatedMin` (deleted ones included), or everything when it is nil.
    public static func tasksRequest(listId: String, updatedMin: Date?, pageToken: String?) -> GoogleCalendarAPI.Builder {
        { GoogleCalendarAPI.request(taskPath(listId: listId), [
            "maxResults": "100", "pageToken": pageToken, "showCompleted": "true", "showHidden": "true",
            "showDeleted": updatedMin == nil ? "false" : "true",
            "updatedMin": updatedMin.map(GoogleCalendarAPI.iso),
        ], accessToken: $0) }
    }

    public static func getTaskRequest(listId: String, taskId: String) -> GoogleCalendarAPI.Builder {
        { GoogleCalendarAPI.request(taskPath(listId: listId, taskId: taskId), [:], accessToken: $0) }
    }

    public struct ListsPage: GoogleCalendarAPI.Paged {
        struct Item: Decodable { var id: String; var title: String? }
        public var nextPageToken: String?
        var items: [Item]?

        public func lists(account: String) -> [TaskList] {
            (items ?? []).map { TaskList(account: account, id: $0.id, title: $0.title ?? "Tasks", syncedAt: nil) }
        }
    }

    public struct TasksPage: GoogleCalendarAPI.Paged {
        public var nextPageToken: String?
        public var items: [GoogleTask]?
    }

    /// A task as the body of an insert or patch.
    public static func body(title: String, notes: String?, due: Date?, calendar: Calendar = .current) -> [String: Any] {
        ["title": title, "notes": notes ?? NSNull(), "due": due.map { Self.due($0, calendar: calendar) } ?? NSNull()]
    }

    public struct GoogleTask: Decodable {
        public var id: String
        var title: String?
        var notes: String?
        var status: String?
        var due: String?
        var parent: String?
        var position: String?
        public var deleted: Bool?

        public func task(account: String, listId: String, calendar: Calendar = .current) -> TaskItem {
            TaskItem(account: account, listId: listId, id: id, title: title ?? "", notes: notes,
                     completed: status == "completed", due: due.flatMap { GoogleCalendarAPI.localDay($0, calendar: calendar) },
                     parent: parent, position: position ?? "")
        }

    }

    /// The `due` value Google expects for a calendar day.
    public static func due(_ day: Date, calendar: Calendar = .current) -> String {
        GoogleCalendarAPI.ymd(day, calendar: calendar) + "T00:00:00.000Z"
    }
}
