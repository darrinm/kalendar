// State behind the Mini Window: the displayed month, the selected day, the agenda list's range,
// search, and the cached events those need (§4.2, §4.3, §9). Views read; the cache is the source.
import AppKit
import KalendarCore
import Observation
import SwiftUI

/// One day in the agenda list or search results.
struct DaySection: Identifiable, Equatable {
    var day: Date
    var allDay: [EventInstance]
    /// Tasks due this day, pinned with the all-day items; today's also holds overdue ones (§4.3, §10).
    var tasks: [TaskItem] = []
    var timed: [EventInstance]
    var id: Date { day }
    var isEmpty: Bool { allDay.isEmpty && tasks.isEmpty && timed.isEmpty }
}

/// The Tasks view's sort (§10).
enum TaskSort: String, CaseIterable {
    case dueDate = "Due Date"
    case myOrder = "My Order"
}

/// What a grid cell shows under the day number (§4.2).
struct DayMarks: Equatable {
    var colors: [Color] = []
    var declined = false
    /// Incomplete tasks due this day: a ✓ under the dots (§4.2).
    var tasks = false
}

@MainActor
@Observable
final class AgendaModel {
    let cache: CalendarCache
    let engine: SyncEngine

    private(set) var today: Date
    /// First day of the month the grid shows.
    private(set) var displayedMonth: Date
    private(set) var selectedDay: Date
    /// Set to ask the list to scroll a day's header to the top.
    private(set) var scrollTarget: Date?
    private(set) var scrollRequest = 0

    private(set) var listStart: Date
    private(set) var listEnd: Date
    private(set) var sections: [DaySection] = []
    private(set) var marks: [Date: DayMarks] = [:]
    private(set) var calendars: [CalendarInfo] = []
    /// Invitations awaiting a reply (§6.2): the badge count and the Notifications popover.
    private(set) var invitations: [EventInstance] = []
    /// The selected row's key: an event's or a task's.
    var selectedEvent: String?
    private(set) var taskLists: [TaskList] = []
    /// The Tasks view (§10) replaces the grid and the agenda.
    var showsTasks = false { didSet { if showsTasks && !oldValue { reloadTasks() } } }
    var taskSort = TaskSort(rawValue: UserDefaults.standard.string(forKey: "taskSort") ?? "") ?? .dueDate {
        didSet {
            UserDefaults.standard.set(taskSort.rawValue, forKey: "taskSort")
            reloadTasks()
        }
    }
    var showCompletedTasks = UserDefaults.standard.bool(forKey: "showCompletedTasks") {
        didSet {
            UserDefaults.standard.set(showCompletedTasks, forKey: "showCompletedTasks")
            reloadTasks()
        }
    }
    /// The Tasks view's rows, in order; `depth` 1 for a subtask.
    private(set) var taskRows: [(task: TaskItem, depth: Int)] = []

    var searchMode = false
    var query = "" { didSet { if searchMode { scheduleSearch() } } }
    var scope: CalendarCache.SearchScope = .all { didSet { scheduleSearch() } }
    private(set) var searchResults: [DaySection] = []

    /// False while the popover is closed: cache changes then only mark the model stale.
    @ObservationIgnored var isVisible = false {
        didSet { if isVisible && stale { reloadAll() } }
    }
    @ObservationIgnored private var stale = false
    @ObservationIgnored private var calendarsByKey: [String: CalendarInfo] = [:]
    @ObservationIgnored private var eventColors: [String: [String: String]] = [:]
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    private var calendar: Calendar { .current }

    static let initialListDays = 60

    init(cache: CalendarCache, engine: SyncEngine) {
        self.cache = cache
        self.engine = engine
        let today = Calendar.current.startOfDay(for: Date())
        self.today = today
        displayedMonth = Calendar.current.dateInterval(of: .month, for: today)!.start
        selectedDay = today
        listStart = today
        listEnd = today
        startList(at: today)
        reloadAll()
    }

    /// The cache changed (sync, write, sign-out).
    func cacheChanged() {
        if isVisible { reloadAll() } else { stale = true }
    }

    // MARK: Navigation

    /// On every open (§4): back to today, the list scrolled to it.
    func resetToToday() {
        today = calendar.startOfDay(for: Date())
        startList(at: today)
        select(today)
    }

    /// Selects a day, shows its month, and scrolls the list to it. A day near the list's range
    /// grows the range; a distant one (Go to Date two years out) starts a new range at that day,
    /// so the list never spans years of empty sections.
    func select(_ day: Date) {
        let day = calendar.startOfDay(for: day)
        selectedDay = day
        displayedMonth = calendar.dateInterval(of: .month, for: day)!.start
        let reach = TimeInterval(Self.initialListDays * 86400)
        if day < listStart.addingTimeInterval(-reach) || day > listEnd.addingTimeInterval(reach) {
            startList(at: day)
        } else {
            listStart = min(listStart, day)
            listEnd = max(listEnd, calendar.date(byAdding: .day, value: 31, to: day)!)
        }
        reloadEvents()
        scrollTarget = day
        scrollRequest += 1
    }

    func moveDay(by days: Int) { select(calendar.date(byAdding: .day, value: days, to: selectedDay)!) }

    /// ←/→ and ‹ ›: the grid moves a month; the selection follows to the same day of that month.
    func moveMonth(by months: Int) { select(calendar.date(byAdding: .month, value: months, to: selectedDay)!) }

    /// Called when the list's last section appears: "All Days" scrolls forward without end (§4.3).
    func extendList() {
        listEnd = calendar.date(byAdding: .day, value: 30, to: listEnd)!
        reloadEvents()
    }

    private func startList(at day: Date) {
        listStart = day
        listEnd = calendar.date(byAdding: .day, value: Self.initialListDays, to: day)!
    }

    // MARK: Reading the cache

    /// The 42 days the grid shows: six weeks starting on the week containing the 1st.
    var gridDays: [Date] {
        let weekday = calendar.component(.weekday, from: displayedMonth)
        let offset = (weekday - calendar.firstWeekday + 7) % 7
        let start = calendar.date(byAdding: .day, value: -offset, to: displayedMonth)!
        return (0..<42).map { calendar.date(byAdding: .day, value: $0, to: start)! }
    }

    /// After the cache changed: calendars, colors and events.
    private func reloadAll() {
        stale = false
        do {
            calendars = try cache.calendars()
            calendarsByKey = Dictionary(uniqueKeysWithValues: calendars.map { ($0.key, $0) })
            eventColors = try cache.eventColors()
            invitations = try cache.pendingInvitations(now: Date())
            taskLists = try cache.taskLists()
        } catch {
            Log.shell.error("cache read failed: \(error.localizedDescription)")
        }
        reloadEvents()
        if showsTasks { reloadTasks() }
        if searchMode { scheduleSearch(delay: 0) }
    }

    /// After navigation: only the events for the grid and the list.
    private func reloadEvents() {
        let grid = gridDays
        let from = min(grid.first!, listStart)
        let to = max(calendar.date(byAdding: .day, value: 1, to: grid.last!)!, listEnd)
        guard let events = try? cache.events(from: from, to: to) else { return }
        let byDay = bucket(events, from: from, to: to)
        // overdue incomplete tasks show under today, not on their past due day (§4.3)
        let tasks = (try? cache.tasks(dueFrom: from, to: to, overdueBefore: today)) ?? []
        let tasksByDay = Dictionary(grouping: tasks) { t in
            !t.completed && t.due! < today ? today : t.due!
        }
        marks = Dictionary(uniqueKeysWithValues: grid.map { day in
            let dayEvents = byDay[day] ?? []
            return (day, DayMarks(colors: dayEvents.filter { !$0.isDeclined }.map(color(for:)),
                                  declined: dayEvents.contains(where: \.isDeclined),
                                  tasks: tasksByDay[day]?.contains { !$0.completed } ?? false))
        })
        sections = days(from: listStart, to: listEnd).map { day in
            var s = section(for: day, events: byDay[day] ?? [])
            s.tasks = (tasksByDay[day] ?? []).sorted { ($0.completed ? 1 : 0, $0.due!, $0.title) < ($1.completed ? 1 : 0, $1.due!, $1.title) }
            return s
        }
    }

    /// The Tasks view's rows (§10): every list merged, subtasks under their parent.
    private func reloadTasks() {
        let all = ((try? cache.allTasks()) ?? []).filter { showCompletedTasks || !$0.completed }
        let keys = Set(all.map(\.key))
        // by the parent's key; a subtask whose parent is hidden (completed, say) is a top-level task, under nil
        let byParent = Dictionary(grouping: all) { (t: TaskItem) -> String? in
            guard let parent = t.parent else { return nil }
            let key = "\(t.listKey)|\(parent)"
            return keys.contains(key) ? key : nil
        }
        let order: (TaskItem, TaskItem) -> Bool = switch taskSort {
        // undated last; then title, so the order is stable
        case .dueDate: { ($0.due ?? .distantFuture, $0.title) < ($1.due ?? .distantFuture, $1.title) }
        case .myOrder: { ($0.listKey, $0.position) < ($1.listKey, $1.position) }
        }
        taskRows = (byParent[nil] ?? []).sorted(by: order).flatMap { root in
            [(root, 0)] + (byParent[root.key] ?? []).sorted { $0.position < $1.position }.map { ($0, 1) }
        }
    }

    /// Search runs 150 ms after the last keystroke, so typing doesn't query the cache per letter.
    private func scheduleSearch(delay: UInt64 = 150_000_000) {
        searchTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            searchResults = []
            return
        }
        let scope = scope
        searchTask = Task {
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            guard !Task.isCancelled, let found = try? cache.search(text, scope: scope) else { return }
            let byDay = Dictionary(grouping: found) { calendar.startOfDay(for: $0.start) }
            searchResults = byDay.keys.sorted().map { section(for: $0, events: byDay[$0]!) }
        }
    }

    private func section(for day: Date, events: [EventInstance]) -> DaySection {
        // "Show declined events" is off (§2); identical events on several calendars show once (§4.3)
        var seen = Set<EventInstance.DuplicateKey>()
        let shown = events.filter { !$0.isDeclined && seen.insert($0.duplicateKey).inserted }
        return DaySection(day: day, allDay: shown.filter(\.allDay), timed: shown.filter { !$0.allDay })
    }

    /// Each event under every day it overlaps. A timed event ending at midnight stops the day before.
    private func bucket(_ events: [EventInstance], from: Date, to: Date) -> [Date: [EventInstance]] {
        var result: [Date: [EventInstance]] = [:]
        for e in events {
            var day = max(calendar.startOfDay(for: e.start), from)
            while day < e.end && day < to {
                result[day, default: []].append(e)
                day = calendar.date(byAdding: .day, value: 1, to: day)!
            }
        }
        return result
    }

    private func days(from: Date, to: Date) -> [Date] {
        var result: [Date] = []
        var day = from
        while day < to {
            result.append(day)
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return result
    }

    // MARK: Presentation helpers

    /// The event's own color when it has one, otherwise its calendar's.
    func color(for event: EventInstance) -> Color {
        Color(hex: event.colorId.flatMap { eventColors[event.account]?[$0] }
            ?? calendarsByKey[event.calendarKey]?.backgroundColor ?? CalendarInfo.fallbackColor)
    }

    func calendar(forKey key: String) -> CalendarInfo? { calendarsByKey[key] }

    func taskList(forKey key: String) -> TaskList? { taskLists.first { $0.key == key } }

    /// Where a new task goes: the account's first list, else any.
    func defaultTaskList(account: String?) -> TaskList? {
        taskLists.first { $0.account == account } ?? taskLists.first
    }

    /// Where a new event goes: the account's primary calendar, else any writable one.
    func defaultCalendar(account: String?) -> CalendarInfo? {
        let writable = calendars.filter(\.isWritable)
        return writable.first { $0.account == account && $0.primary } ?? writable.first
    }

    func calendarName(for event: EventInstance) -> String {
        calendarsByKey[event.calendarKey]?.summary ?? event.calendarId
    }

    /// The one event that gets the Join pill (§4.3): in progress or starting within 15 minutes, with a
    /// video link, not declined. With several, the one that started or starts last.
    func joinCandidate(now: Date) -> String? {
        sections.first { calendar.isDate($0.day, inSameDayAs: now) }?.timed
            .filter { $0.conferenceURL != nil && $0.end > now && $0.start <= now.addingTimeInterval(15 * 60) }
            .max { $0.start < $1.start }?.key
    }
}

extension Color {
    /// "#rrggbb"
    init(hex: String) {
        let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x9A9A9A
        self.init(light: value, dark: value)
    }
}
