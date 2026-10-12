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
    var timed: [EventInstance]
    var id: Date { day }
    var isEmpty: Bool { allDay.isEmpty && timed.isEmpty }
}

/// What a grid cell shows under the day number (§4.2).
struct DayMarks: Equatable {
    var colors: [Color] = []
    var declined = false
}

@MainActor
@Observable
final class AgendaModel {
    let cache: CalendarCache
    let engine: SyncEngine

    private(set) var today: Date
    /// First day of the month the grid shows.
    var displayedMonth: Date
    private(set) var selectedDay: Date
    /// Set to ask the list to scroll a day's header to the top.
    private(set) var scrollTarget: Date?
    private(set) var scrollRequest = 0

    private(set) var listStart: Date
    private(set) var listEnd: Date
    private(set) var sections: [DaySection] = []
    private(set) var marks: [Date: DayMarks] = [:]
    private(set) var calendars: [CalendarInfo] = []
    var selectedEvent: String?

    var searchMode = false
    var query = "" { didSet { if searchMode { runSearch() } } }
    var scope: CalendarCache.SearchScope = .all { didSet { runSearch() } }
    private(set) var searchResults: [DaySection] = []

    private var calendarColors: [String: String] = [:]
    private var eventColors: [String: [String: String]] = [:]
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
        listEnd = Calendar.current.date(byAdding: .day, value: Self.initialListDays, to: today)!
        reload()
        engine.onChange = { [weak self] in self?.reload() }
    }

    // MARK: Navigation

    /// On every open (§4): back to today, the list scrolled to it.
    func resetToToday() {
        today = calendar.startOfDay(for: Date())
        listStart = today
        listEnd = calendar.date(byAdding: .day, value: Self.initialListDays, to: today)!
        select(today)
    }

    /// Selects a day, shows its month, and scrolls the list to it. A day near the list's range
    /// grows the range; a distant one (Go to Date two years out) starts a new range at that day,
    /// so the list never spans years of empty sections.
    func select(_ day: Date) {
        let day = calendar.startOfDay(for: day)
        selectedDay = day
        displayedMonth = calendar.dateInterval(of: .month, for: day)!.start
        let needed = calendar.date(byAdding: .day, value: 31, to: day)!
        let reach = TimeInterval(Self.initialListDays * 86400)
        if day < listStart.addingTimeInterval(-reach) || day > listEnd.addingTimeInterval(reach) {
            listStart = day
            listEnd = calendar.date(byAdding: .day, value: Self.initialListDays, to: day)!
        } else {
            if day < listStart { listStart = day }
            if needed > listEnd { listEnd = needed }
        }
        reload()
        scrollTarget = day
        scrollRequest += 1
    }

    func moveDay(by days: Int) { select(calendar.date(byAdding: .day, value: days, to: selectedDay)!) }

    /// ←/→ and ‹ ›: the grid moves a month; the selection follows to the same day of that month.
    func moveMonth(by months: Int) { select(calendar.date(byAdding: .month, value: months, to: selectedDay)!) }

    /// Called when the list's last section appears: "All Days" scrolls forward without end (§4.3).
    func extendList() {
        listEnd = calendar.date(byAdding: .day, value: 30, to: listEnd)!
        reload()
    }

    // MARK: Reading the cache

    /// The 42 days the grid shows: six weeks starting on the week containing the 1st.
    var gridDays: [Date] {
        let weekday = calendar.component(.weekday, from: displayedMonth)
        let offset = (weekday - calendar.firstWeekday + 7) % 7
        let start = calendar.date(byAdding: .day, value: -offset, to: displayedMonth)!
        return (0..<42).map { calendar.date(byAdding: .day, value: $0, to: start)! }
    }

    func reload() {
        do {
            calendars = try cache.calendars()
            calendarColors = Dictionary(uniqueKeysWithValues: calendars.map { ($0.key, $0.backgroundColor) })
            eventColors = try cache.eventColors()

            let grid = gridDays
            let from = min(grid.first!, listStart)
            let to = max(calendar.date(byAdding: .day, value: 1, to: grid.last!)!, listEnd)
            let events = try cache.events(from: from, to: to)
            let byDay = bucket(events, from: from, to: to)

            marks = Dictionary(uniqueKeysWithValues: grid.map { day in
                let dayEvents = byDay[day] ?? []
                return (day, DayMarks(colors: dayEvents.filter { !$0.isDeclined }.map(color(for:)),
                                      declined: dayEvents.contains(where: \.isDeclined)))
            })
            sections = days(from: listStart, to: listEnd).map { section(for: $0, events: byDay[$0] ?? []) }
            if searchMode { runSearch() }
        } catch {
            Log.shell.error("cache read failed: \(error.localizedDescription)")
        }
    }

    private func runSearch() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let found = try? cache.search(text, scope: scope) else {
            searchResults = []
            return
        }
        let byDay = Dictionary(grouping: found) { calendar.startOfDay(for: $0.start) }
        searchResults = byDay.keys.sorted().map { section(for: $0, events: byDay[$0]!) }
    }

    private func section(for day: Date, events: [EventInstance]) -> DaySection {
        // "Show declined events" is off (§2); identical events on several calendars show once (§4.3)
        var seen = Set<String>()
        let shown = events.filter { e in
            !e.isDeclined && seen.insert("\(e.summary)|\(e.start)|\(e.end)|\(e.location ?? "")").inserted
        }
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
        let hex = event.colorId.flatMap { eventColors[event.account]?[$0] }
            ?? calendarColors["\(event.account)|\(event.calendarId)"] ?? "#9A9A9A"
        return Color(hex: hex)
    }

    func calendarName(for event: EventInstance) -> String {
        calendars.first { $0.account == event.account && $0.id == event.calendarId }?.summary ?? event.calendarId
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
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}
