// The calendar window (§22): Day, Week and Month views of the selected calendars, in a window of
// its own. Events open in the detail form, move and resize by dragging, and new ones start from a
// click or drag on empty time (or an empty part of a month day).
import AppKit
import KalendarCore
import SwiftUI

@MainActor
final class CalendarWindowController {
    private let model: CalendarWindowModel
    private var window: NSWindow?
    private let popover = EventPopover()

    init(model: CalendarWindowModel) {
        self.model = model
        model.showForm = { [weak self] form, onAdd, closed in
            guard let self else { return }
            // an existing event saves on close (§6); a new one is added only by Add Event
            let save: (() -> Bool)? = form.isNew ? nil : { form.shouldClose() }
            popover.show(EventEditor(model: form, onAdd: onAdd), in: window, shouldClose: save, onClose: closed)
        }
        model.closeForm = { [weak self] in self?.popover.dismiss() }
    }

    /// A sync changed the cache: the open window shows it; a closed one reads it when it opens.
    func cacheChanged() {
        if window?.isVisible == true { model.reload() }
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: CalendarView(model: model)))
            window.title = "Kalendar"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 1100, height: 760))
            window.contentMinSize = NSSize(width: 560, height: 420)
            window.center()
            window.setFrameAutosaveName("CalendarWindow")
            self.window = window
        }
        model.reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
@Observable
final class CalendarWindowModel {
    enum Mode: String, CaseIterable {
        case day = "Day", week = "Week", month = "Month"
    }

    let agenda: AgendaModel
    let accounts: AccountStore
    let writer: EventWriter

    var mode: Mode = .week { didSet { if mode != oldValue { reload() } } }
    /// The day the view is about: the day shown, or one day of the week or month shown.
    private(set) var anchor: Date
    /// The events in the shown range, as the agenda shows them (§4.3, §12).
    private(set) var events: [EventInstance] = []

    /// Shows a form beside the pointer, with its Add Event action; the closure runs when it closes.
    /// Set by the window controller, with `closeForm`.
    @ObservationIgnored var showForm: (EventEditorModel, (() -> Void)?, @escaping () -> Void) -> Void = { _, _, _ in }
    @ObservationIgnored var closeForm: () -> Void = {}
    @ObservationIgnored private var newEvent: EventEditorModel?

    init(agenda: AgendaModel, accounts: AccountStore, writer: EventWriter) {
        self.agenda = agenda
        self.accounts = accounts
        self.writer = writer
        anchor = Calendar.current.startOfDay(for: Date())
    }

    private var calendar: Calendar { Preferences.shared.calendar }

    // MARK: Range

    /// The Day or Week view's days.
    var days: [Date] {
        switch mode {
        case .day: [anchor]
        case .week, .month:
            (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart(anchor)) }
        }
    }

    /// The Month view's weeks: from the week holding the 1st through the week holding the last day.
    var weeks: [[Date]] {
        guard let month = calendar.dateInterval(of: .month, for: anchor) else { return [] }
        var weeks: [[Date]] = []
        var start = weekStart(month.start)
        while start < month.end {
            weeks.append((0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) })
            start = calendar.date(byAdding: .day, value: 7, to: start) ?? month.end
        }
        return weeks
    }

    private func weekStart(_ day: Date) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: day)?.start ?? calendar.startOfDay(for: day)
    }

    private var range: (from: Date, to: Date) {
        let shown = mode == .month ? weeks.flatMap { $0 } : days
        let first = shown.first ?? anchor
        return (first, calendar.date(byAdding: .day, value: 1, to: shown.last ?? anchor) ?? first)
    }

    var title: String {
        switch mode {
        case .day: anchor.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
        case .week:
            "\(days.first!.formatted(.dateTime.month(.abbreviated).day())) – \(days.last!.formatted(.dateTime.month(.abbreviated).day().year()))"
        case .month: anchor.formatted(.dateTime.month(.wide).year())
        }
    }

    func step(_ direction: Int) {
        let unit: Calendar.Component = switch mode { case .day: .day; case .week: .weekOfYear; case .month: .month }
        anchor = calendar.date(byAdding: unit, value: direction, to: anchor) ?? anchor
        reload()
    }

    func goToToday() {
        anchor = calendar.startOfDay(for: Date())
        reload()
    }

    /// A month day's number: that day, in the Day view.
    func showDay(_ day: Date) {
        anchor = calendar.startOfDay(for: day)
        mode = .day
        reload()
    }

    func reload() {
        events = agenda.shown((try? agenda.cache.events(from: range.from, to: range.to)) ?? [])
    }

    // MARK: Blocks

    func block(_ e: EventInstance) -> GridBlock {
        GridBlock(id: e.key, start: e.start, end: e.end, title: e.summary, color: agenda.color(for: e),
                  outlined: e.isTentative || e.isDeclined, movable: canMove(e))
    }

    /// An invitation's time is the organizer's to change; a read-only calendar takes no writes.
    private func canMove(_ e: EventInstance) -> Bool { agenda.isWritable(e) && !e.isInvitation }

    func event(_ id: String) -> EventInstance? { events.first { $0.key == id } }

    // MARK: Forms

    /// The event's detail form, saved when it closes (§6).
    func open(_ id: String) {
        guard let event = event(id) else { return }
        showForm(EventEditorModel(event: event, agenda: agenda, writer: writer), nil) {}
    }

    /// A new event's form for [start, end) on the default calendar (§12). `done` runs when it closes.
    func create(_ start: Date, _ end: Date, done: @escaping () -> Void = {}) {
        guard let calendar = agenda.defaultCalendar(account: accounts.accounts.first?.email) else { return }
        var draft = EventDraft(parsed: NLParser().parse(""), account: calendar.account, calendarId: calendar.id)
        draft.summary = ""
        // the empty parse is all-day; a timed event is busy, with the calendar's default alerts
        draft.allDay = false
        draft.busy = true
        draft.reminders = Reminders()
        draft.start = start
        draft.end = end
        let form = EventEditorModel(newDraft: draft, agenda: agenda, writer: writer)
        newEvent = form
        showForm(form, { [weak self] in self?.add(form) }) { [weak self] in
            if self?.newEvent === form { self?.newEvent = nil }
            done()
        }
    }

    /// A month day's empty space: an event of the default duration at the day's start (§12).
    func create(on day: Date) {
        let start = calendar.date(bySettingHour: Preferences.shared.dayStartHour, minute: 0, second: 0, of: day) ?? day
        create(start, start.addingTimeInterval(TimeInterval(Preferences.shared.defaultDuration * 60)))
    }

    private func add(_ form: EventEditorModel) {
        guard form.canAdd else { return }
        // a form closed or replaced while its Zoom meeting was created adds nothing
        form.commit { [weak self] draft in
            guard let self, newEvent === form else { return }
            writer.insert(draft)
            if Preferences.shared.playSounds { NSSound(named: "Pop")?.play() }
            closeForm()
            reload()
        }
    }

    // MARK: Moves

    /// A drag's new times. A repeating event asks first (§8.1); "All" moves the series by the same
    /// amount, which needs the series' own times, loaded first.
    func move(_ id: String, start: Date, end: Date) {
        guard let event = event(id), canMove(event), let scope = Dialogs.scope(for: event) else { return }
        let original = EventDraft(event, recurrence: nil)
        var draft = original
        draft.start = start
        draft.end = end
        if scope == .occurrence {
            writer.save(event, original: original, draft: draft, scope: scope, series: nil)
            reload()
        } else {
            Task {
                writer.save(event, original: original, draft: draft, scope: scope, series: await writer.series(of: event))
                reload()
            }
        }
    }

    /// A month view drop: the event on `day`, at the same time of day.
    func move(_ id: String, to day: Date) {
        guard let event = event(id) else { return }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: event.start), to: calendar.startOfDay(for: day)).day ?? 0
        guard days != 0, let start = calendar.date(byAdding: .day, value: days, to: event.start),
              let end = calendar.date(byAdding: .day, value: days, to: event.end) else { return }
        move(id, start: start, end: end)
    }

    /// Delete, from a block's menu (§8.2).
    func delete(_ id: String) {
        guard let event = event(id), canMove(event), let scope = Dialogs.scope(for: event) else { return }
        writer.delete(event, scope: scope)
        reload()
    }
}

// MARK: - Views

struct CalendarView: View {
    @Bindable var model: CalendarWindowModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { model.step(-1) } label: { Image(systemName: "chevron.left") }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .accessibilityLabel("Previous")
                Button { model.step(1) } label: { Image(systemName: "chevron.right") }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .accessibilityLabel("Next")
                Button("Today") { model.goToToday() }
                    .keyboardShortcut("t", modifiers: .command)
                Text(model.title).uiFont(17, weight: .semibold).foregroundStyle(Theme.text)
                Spacer()
                Picker("View", selection: $model.mode) {
                    ForEach(CalendarWindowModel.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .buttonStyle(.borderless)
            .padding(16)
            // ⌘1 Day, ⌘2 Week, ⌘3 Month
            .background {
                ForEach(Array(CalendarWindowModel.Mode.allCases.enumerated()), id: \.offset) { index, mode in
                    Button("") { model.mode = mode }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                        .hidden()
                }
            }
            switch model.mode {
            case .day, .week:
                let timed = model.events.filter { !$0.allDay }.map(model.block)
                let allDay = model.events.filter(\.allDay).map(model.block)
                TimeGrid(days: model.days, columns: [timed], allDay: allDay,
                         onCreate: { start, end, done in model.create(start, end, done: done) },
                         onOpen: { model.open($0.id) },
                         onMove: { block, start, end in model.move(block.id, start: start, end: end) },
                         onDelete: { model.delete($0.id) })
                    .id(model.mode)   // a new scroll position for each view
            case .month:
                MonthView(model: model)
            }
        }
        .background(Theme.background)
        .tint(Theme.accent)
        .uiFont(13)
    }
}

/// The month: a row per week, a cell per day with its events (all-day first, then by start); more
/// than fit show as "+N more", which opens the day. Events drag to another day.
private struct MonthView: View {
    let model: CalendarWindowModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(model.weeks.first ?? [], id: \.self) { day in
                    Text(day.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                        .uiFont(11, weight: .semibold).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.bottom, 6)
            Theme.line.frame(height: 1)
            GeometryReader { geo in
                let rows = max(model.weeks.count, 1)
                let height = geo.size.height / CGFloat(rows)
                // rows of 15 pt below the day number
                let fits = max(Int((height - 26) / 17), 1)
                VStack(spacing: 0) {
                    ForEach(model.weeks, id: \.self) { week in
                        HStack(spacing: 0) {
                            ForEach(week, id: \.self) { day in
                                MonthDayCell(model: model, day: day, fits: fits)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .overlay(alignment: .trailing) { Theme.line.frame(width: 1) }
                            }
                        }
                        .frame(height: height)
                        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
                    }
                }
            }
        }
        .padding(.horizontal, 8)
    }
}

private struct MonthDayCell: View {
    let model: CalendarWindowModel
    let day: Date
    let fits: Int

    var body: some View {
        let calendar = Preferences.shared.calendar
        let next = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        let events = model.events.filter { $0.start < next && $0.end > day }
            .sorted { ($0.allDay ? 0 : 1, $0.start) < ($1.allDay ? 0 : 1, $1.start) }
        let inMonth = calendar.isDate(day, equalTo: model.anchor, toGranularity: .month)
        let today = calendar.isDateInToday(day)
        // with more than fit, the last row says how many more
        let shown = events.count > fits ? Array(events.prefix(fits - 1)) : events
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Spacer()
                Button { model.showDay(day) } label: {
                    Text(day.formatted(.dateTime.day()))
                        .uiFont(12, weight: today ? .bold : .regular)
                        .foregroundStyle(today ? .white : inMonth ? Theme.text : Theme.muted)
                        .frame(minWidth: 22, minHeight: 22)
                        .background(today ? Theme.accent : .clear, in: Circle())
                }
                .buttonStyle(.plain)
            }
            ForEach(shown, id: \.key) { e in
                MonthEventRow(event: e, color: model.agenda.color(for: e))
                    .contentShape(Rectangle())
                    .onTapGesture { model.open(e.key) }
                    .draggable(e.key)
                    .contextMenu {
                        if model.block(e).movable { Button("Delete") { model.delete(e.key) } }
                    }
            }
            if shown.count < events.count {
                Button("+\(events.count - shown.count) more") { model.showDay(day) }
                    .buttonStyle(.plain).uiFont(11).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture { model.create(on: day) }
        .dropDestination(for: String.self) { ids, _ in
            for id in ids { model.move(id, to: day) }
            return !ids.isEmpty
        }
    }
}

/// A month day's event: a colored bar for an all-day event, a dot and the start time for a timed one.
private struct MonthEventRow: View {
    let event: EventInstance
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            if event.allDay {
                Text(event.summary).uiFont(11, weight: .semibold).foregroundStyle(.white).lineLimit(1)
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(color.opacity(0.9), in: RoundedRectangle(cornerRadius: 3))
            } else {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(event.start.formatted(date: .omitted, time: .shortened)).uiFont(11).foregroundStyle(Theme.muted)
                Text(event.summary).uiFont(11).foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .frame(height: 15)
        .help("\(event.summary), \(event.start.formatted(date: .omitted, time: .shortened))")
    }
}
