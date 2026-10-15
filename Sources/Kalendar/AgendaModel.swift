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
    /// The selected row: an `EventInstance.key` or a `TaskItem.key`.
    var selection: String?
    private(set) var taskLists: [TaskList] = []
    /// The Tasks view (§10) replaces the grid and the agenda.
    var showsTasks = false { didSet { if showsTasks && !oldValue { reloadTasks() } } }
    /// Kept in Preferences; a change reloads through `settingsChanged`.
    var taskSort: TaskSort {
        get { prefs.taskSort }
        set { prefs.taskSort = newValue }
    }
    var showCompletedTasks: Bool {
        get { prefs.showCompletedTasks }
        set { prefs.showCompletedTasks = newValue }
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
    /// The user's calendar with the Start week on setting (§12).
    var calendar: Calendar { prefs.calendar }
    private var prefs: Preferences { .shared }

    /// "All days": the first stretch loaded, extended on scroll (§4.3).
    static let initialListDays = 60
    /// Whether the list grows as it scrolls ("List shows: All days").
    var listIsEndless: Bool { prefs.listDays == 0 }

    init(cache: CalendarCache, engine: SyncEngine) {
        self.cache = cache
        self.engine = engine
        let today = Preferences.shared.calendar.startOfDay(for: Date())
        self.today = today
        displayedMonth = Preferences.shared.calendar.dateInterval(of: .month, for: today)!.start
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

    /// On every open (§4) and ⌘T: back to today, the list scrolled to it. The row selection goes
    /// too, so ↓ starts at today rather than at a row scrolled out of view.
    func resetToToday() {
        selection = nil
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
        if !listIsEndless || day < listStart.addingTimeInterval(-reach) || day > listEnd.addingTimeInterval(reach) {
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
        listEnd = calendar.date(byAdding: .day, value: listIsEndless ? Self.initialListDays : prefs.listDays, to: day)!
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
        let tasks = prefs.showTasksInList ? visible((try? cache.tasks(dueFrom: from, to: to, overdueBefore: today)) ?? []) : []
        let tasksByDay = Dictionary(grouping: tasks) { t in
            let due = t.due!
            return !t.completed && due < today ? today : due
        }
        marks = Dictionary(uniqueKeysWithValues: grid.map { day in
            // declined events never get a dot, whatever "Show declined events" says (§4.2)
            (day, DayMarks(colors: (byDay[day] ?? []).filter { !$0.isDeclined }.map(color(for:)),
                           tasks: tasksByDay[day]?.contains { !$0.completed } ?? false))
        })
        sections = days(from: listStart, to: listEnd).map { day in
            var s = section(for: day, events: byDay[day] ?? [])
            s.tasks = (tasksByDay[day] ?? []).sorted { ($0.completed ? 1 : 0, $0.dueDay!, $0.title) < ($1.completed ? 1 : 0, $1.dueDay!, $1.title) }
            return s
        }
    }

    /// Tasks on lists the Calendars settings show, completed ones only when shown (§12).
    private func visible(_ tasks: [TaskItem]) -> [TaskItem] {
        tasks.filter { !prefs.hiddenTaskLists.contains($0.listKey) && (showCompletedTasks || !$0.completed) }
    }

    /// Settings that change what the grid or the list shows.
    /// A new list length starts the list again; other settings keep how far it has scrolled.
    func settingsChanged(restartList: Bool) {
        if restartList { startList(at: selectedDay) }
        cacheChanged()
    }

    /// The Tasks view's rows (§10): every list merged, subtasks under their parent.
    private func reloadTasks() {
        let all = visible((try? cache.allTasks()) ?? [])
        let keys = Set(all.map(\.key))
        // by the parent's key; a subtask whose parent is hidden (completed, say) is a top-level task, under nil
        let byParent = Dictionary(grouping: all) { (t: TaskItem) -> String? in
            guard let parent = t.parent else { return nil }
            let key = "\(t.listKey)|\(parent)"
            return keys.contains(key) ? key : nil
        }
        // open tasks before completed ones in either sort
        let order: (TaskItem, TaskItem) -> Bool = switch taskSort {
        // open: soonest due first, undated last, then title so the order is stable. Completed: most recent first, so years-old ones
        // don't fill the top of the list
        case .dueDate: { a, b in
            if a.completed != b.completed { return !a.completed }
            if a.completed { return (b.dueDay ?? "", a.title) < (a.dueDay ?? "", b.title) }
            return (a.dueDay ?? "~", a.title) < (b.dueDay ?? "~", b.title)
        }
        case .myOrder: { ($0.completed ? 1 : 0, $0.listKey, $0.position) < ($1.completed ? 1 : 0, $1.listKey, $1.position) }
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
        let shown = shown(events)
        return DaySection(day: day, allDay: shown.filter(\.allDay), timed: shown.filter { !$0.allDay })
    }

    /// The events the user sees: declined ones only with "Show declined events" (§12), and
    /// identical events on several calendars once (§4.3) unless "Combine identical events" is off.
    /// Of identical copies, one on a calendar the user can write is kept: another account's copy of
    /// the same calendar may be read-only, and opening or dragging it could change nothing.
    func shown(_ events: [EventInstance]) -> [EventInstance] {
        let visible = events.filter { prefs.showDeclined || !$0.isDeclined }
        guard prefs.combineIdentical else { return visible }
        let writable = Set(visible.filter(isWritable).map(\.duplicateKey))
        var seen = Set<EventInstance.DuplicateKey>()
        return visible.filter { e in
            (isWritable(e) || !writable.contains(e.duplicateKey)) && seen.insert(e.duplicateKey).inserted
        }
    }

    /// Each event under every day it overlaps. A timed event ending at midnight stops the day before.
    func bucket(_ events: [EventInstance], from: Date, to: Date) -> [Date: [EventInstance]] {
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

    /// False for an event on a calendar the user can only read (holidays, a shared calendar): Google
    /// refuses every write to it. An event whose calendar is not cached counts as writable.
    func isWritable(_ event: EventInstance) -> Bool { calendar(forKey: event.calendarKey)?.isWritable != false }

    func taskList(forKey key: String) -> TaskList? { taskLists.first { $0.key == key } }

    /// Where a new task goes: the account's first list, else any.
    func defaultTaskList(account: String?) -> TaskList? {
        taskLists.first { $0.account == account } ?? taskLists.first
    }

    /// Where a new event goes: the Default calendar setting (§12) when it is writable, else the
    /// account's primary calendar, else any writable one.
    func defaultCalendar(account: String?) -> CalendarInfo? {
        if let key = prefs.defaultCalendar, let c = calendar(forKey: key), c.isWritable { return c }
        let writable = calendars.filter(\.isWritable)
        return writable.first { $0.account == account && $0.primary } ?? writable.first
    }

    func calendarName(for event: EventInstance) -> String {
        calendarsByKey[event.calendarKey]?.summary ?? event.calendarId
    }

    /// The key of the one event that gets the Join pill (§4.3). Tomorrow's section too, so a meeting
    /// just after midnight gets the pill at 23:45, as the menu bar's Join item does (§3).
    func joinCandidate(now: Date) -> String? {
        let today = calendar.startOfDay(for: now), soon = now.addingTimeInterval(ConferenceDetector.joinLead)
        let days = sections.drop { $0.day < today }.prefix { $0.day <= soon }
        return ConferenceDetector.joinCandidate(in: days.flatMap(\.timed), now: now)?.key
    }
}

extension Color {
    /// "#rrggbb"
    init(hex: String) {
        let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x9A9A9A
        self.init(light: value, dark: value)
    }
}
