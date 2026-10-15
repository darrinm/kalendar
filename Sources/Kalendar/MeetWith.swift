// Meet With (§21): a week grid with the user's events and the chosen people's side by side in each
// day, so a slot open to everyone stands out. Clicking a slot, or dragging across slots, opens the
// new-event form for it, with the people invited.
import AppKit
import KalendarCore
import SwiftUI

@MainActor
final class MeetWithWindowController {
    private let model: MeetWithModel
    private var window: NSWindow?

    init(model: MeetWithModel) { self.model = model }

    /// A sync changed the cache: the open window shows the user's new events; a closed one reads
    /// them when it opens.
    func cacheChanged() {
        if window?.isVisible == true { model.cacheChanged() }
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: MeetWithView(model: model)))
            window.title = "Meet With"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 1000, height: 720))
            window.contentMinSize = NSSize(width: 640, height: 420)
            window.center()
            window.setFrameAutosaveName("MeetWith")
            self.window = window
        }
        model.opened()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
@Observable
final class MeetWithModel {
    let agenda: AgendaModel
    let accounts: AccountStore
    let writer: EventWriter

    /// The chosen people, in the order added.
    private(set) var people: [Contact] = []
    /// Each person's week, by lowercased email; missing while it loads.
    private(set) var schedules: [String: Availability.Schedule] = [:]
    /// The user's own timed events this week.
    private(set) var mine: [Availability.Block] = []
    private(set) var weekStart: Date
    var query = "" { didSet { if query != oldValue { refreshSuggestions() } } }
    private(set) var suggestions: [Contact] = []
    var selected = 0
    /// The new-event form open on a clicked slot.
    var newEvent: EventEditorModel?
    @ObservationIgnored private var contacts: [Contact]?

    init(agenda: AgendaModel, accounts: AccountStore, writer: EventWriter) {
        self.agenda = agenda
        self.accounts = accounts
        self.writer = writer
        weekStart = Self.week(of: Date())
    }

    private static func week(of day: Date) -> Date {
        let calendar = Preferences.shared.calendar
        return calendar.dateInterval(of: .weekOfYear, for: day)?.start ?? calendar.startOfDay(for: day)
    }

    var days: [Date] {
        (0..<7).compactMap { Preferences.shared.calendar.date(byAdding: .day, value: $0, to: weekStart) }
    }

    private var weekEnd: Date { Preferences.shared.calendar.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart }

    func move(weeks: Int) {
        guard let start = Preferences.shared.calendar.date(byAdding: .weekOfYear, value: weeks, to: weekStart) else { return }
        weekStart = start
        reload()
    }

    func goToToday() {
        weekStart = Self.week(of: Date())
        reload()
    }

    // MARK: People

    private func refreshSuggestions() {
        let all = contacts ?? (try? agenda.cache.allContacts()) ?? []
        contacts = all
        let chosen = Set(people.map { $0.email.lowercased() })
        suggestions = all.matching(query).filter { !chosen.contains($0.email.lowercased()) }
        selected = 0
    }

    /// Enter: the selected suggestion, else the typed text when it is an email address.
    func submit() {
        if suggestions.indices.contains(selected) {
            add(suggestions[selected])
        } else {
            let text = query.trimmingCharacters(in: .whitespaces)
            guard text.contains("@"), !text.contains(" ") else { return }
            add(Contact(account: "", email: text, name: nil, photoURL: nil))
        }
    }

    func add(_ contact: Contact) {
        query = ""
        let key = contact.email.lowercased()
        guard !people.contains(where: { $0.email.lowercased() == key }),
              !accounts.accounts.contains(where: { $0.email.lowercased() == key }) else { return }
        people.append(contact)
        load(contact.email)
        cacheChanged()
    }

    func remove(_ contact: Contact) {
        people.removeAll { $0.email == contact.email }
        schedules[contact.email.lowercased()] = nil
        cacheChanged()
    }

    // MARK: Loading

    private func reload() {
        schedules = [:]
        cacheChanged()
        for p in people { load(p.email) }
    }

    private func load(_ email: String) {
        let (week, to) = (weekStart, weekEnd)
        Task {
            let schedule = await Availability.load(email, from: week, to: to, accounts: accounts)
            // the week changed or the person was removed while it loaded
            guard week == weekStart, people.contains(where: { $0.email == email }) else { return }
            schedules[email.lowercased()] = schedule
        }
    }

    /// The user's own events, from the cache: timed, busy, not declined, each once (§4.3). A chosen
    /// person's calendar the user subscribes to is that person's time, not the user's.
    /// The window opened: contacts are read again at the next search, and the user's events now.
    func opened() {
        contacts = nil
        cacheChanged()
    }

    func cacheChanged() {
        let theirs = Set(people.map { $0.email.lowercased() })
        var seen = Set<EventInstance.DuplicateKey>()
        mine = ((try? agenda.cache.events(from: weekStart, to: weekEnd)) ?? [])
            .filter { !$0.allDay && !$0.isDeclined && $0.transparency != "transparent"
                && !theirs.contains($0.calendarId.lowercased()) && seen.insert($0.duplicateKey).inserted }
            .map { Availability.Block(start: $0.start, end: $0.end, title: $0.summary) }
    }

    // MARK: New event

    /// Opens the new-event form for [start, end): the people invited, on the default calendar of the
    /// account in the first person's domain.
    func openSlot(_ start: Date, end: Date) {
        let account = people.first.map { accounts.emails(preferringDomainOf: $0.email).first } ?? accounts.accounts.first?.email
        guard let calendar = agenda.defaultCalendar(account: account) else { return }
        var draft = EventDraft(parsed: NLParser().parse(""), account: calendar.account, calendarId: calendar.id)
        draft.summary = ""
        // the empty parse is all-day; a timed event is busy, with the calendar's default alerts
        draft.allDay = false
        draft.busy = true
        draft.reminders = Reminders()
        draft.start = start
        draft.end = end
        draft.invite(people.map { ($0.email, $0.name) })
        newEvent = EventEditorModel(newDraft: draft, agenda: agenda, writer: writer)
    }

    func addEvent() {
        guard let form = newEvent, form.canAdd else { return }
        // a form closed or replaced while its Zoom meeting was created adds nothing
        form.commit { [weak self] draft in
            guard let self, newEvent === form else { return }
            writer.insert(draft)
            if Preferences.shared.playSounds { NSSound(named: "Pop")?.play() }
            newEvent = nil
            cacheChanged()
        }
    }
}

// MARK: - Views

/// The user's color, then one per person in the order added.
private let personColors: [Color] = [0x8E5BD9, 0xE6862E, 0x2E9E5B, 0xD9468F, 0x1F9AA8, 0xC9A227]
    .map { Color(light: $0, dark: $0) }

private func color(_ index: Int) -> Color { index == 0 ? Theme.accent : personColors[(index - 1) % personColors.count] }

struct MeetWithView: View {
    @Bindable var model: MeetWithModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PeopleField(model: model)
                .padding([.horizontal, .top], 16)
                .zIndex(1)   // the suggestion list draws over the grid
            HStack(spacing: 12) {
                Button { model.move(weeks: -1) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Previous week")
                Button { model.move(weeks: 1) } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel("Next week")
                Button("Today") { model.goToToday() }
                Text(weekTitle).uiFont(15, weight: .semibold).foregroundStyle(Theme.text)
                Spacer()
                Legend(model: model)
            }
            .buttonStyle(.borderless)
            .padding(16)
            WeekGrid(model: model)
        }
        .background(Theme.background)
        .tint(Theme.accent)
        .uiFont(13)
    }

    private var weekTitle: String {
        guard let first = model.days.first, let last = model.days.last else { return "" }
        return "\(first.formatted(.dateTime.month(.abbreviated).day())) – \(last.formatted(.dateTime.month(.abbreviated).day().year()))"
    }
}

/// "Meet with…": the chosen people as removable chips, and a search field with contact suggestions.
private struct PeopleField: View {
    @Bindable var model: MeetWithModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Meet with").foregroundStyle(Theme.muted)
                ForEach(Array(model.people.enumerated()), id: \.element.email) { index, person in
                    HStack(spacing: 4) {
                        Circle().fill(color(index + 1)).frame(width: 8, height: 8)
                        Text(person.name ?? person.email).foregroundStyle(Theme.text).lineLimit(1)
                        Button { model.remove(person) } label: { Image(systemName: "xmark").uiFont(9) }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.muted)
                            .accessibilityLabel("Remove \(person.name ?? person.email)")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.card, in: Capsule())
                    .overlay(Capsule().stroke(color(index + 1), lineWidth: 1))
                }
                TextField("Search for people", text: $model.query)
                    .textFieldStyle(.plain)
                    .onSubmit { model.submit() }
                    .onKeyPress(.downArrow) {
                        model.selected = min(model.selected + 1, max(model.suggestions.count - 1, 0))
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        model.selected = max(model.selected - 1, 0)
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        guard !model.query.isEmpty else { return .ignored }
                        model.query = ""
                        return .handled
                    }
            }
            .padding(8)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
        }
        .overlay(alignment: .topLeading) {
            if !model.suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.suggestions.enumerated()), id: \.element.email) { index, contact in
                        ContactRow(contact: contact)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(index == model.selected ? Theme.accent.opacity(0.25) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                            .onTapGesture { model.add(contact) }
                    }
                }
                .padding(4)
                .frame(width: 320)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
                .shadow(radius: 8)
                .offset(x: 80, y: 40)
            }
        }
    }
}

/// Who each color is, and whose calendar Kalendar could not read.
private struct Legend: View {
    let model: MeetWithModel

    var body: some View {
        HStack(spacing: 12) {
            entry("Me", color: color(0), note: nil)
            ForEach(Array(model.people.enumerated()), id: \.element.email) { index, person in
                let name = String((person.name ?? person.email).split(whereSeparator: { $0 == " " || $0 == "@" }).first ?? "")
                let note: String? = switch model.schedules[person.email.lowercased()] {
                case nil: "loading…"
                case .busy: "busy times only"
                case .unavailable: "calendar not shared"
                case .events: nil
                }
                entry(name, color: color(index + 1), note: note)
            }
        }
        .uiFont(12)
    }

    private func entry(_ name: String, color: Color, note: String?) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(name).foregroundStyle(Theme.text)
            if let note { Text(note).foregroundStyle(Theme.muted) }
        }
    }
}

/// Hours down the side, the week's days across, each day split into a column per person (the user
/// first). The slot under the pointer is highlighted; a click opens the new-event form there, and a
/// drag opens it for the slots dragged across.
private struct WeekGrid: View {
    @Bindable var model: MeetWithModel
    @State private var highlight = SlotHighlight()
    @State private var clicked: CGRect = .zero

    private let hourHeight: CGFloat = 48
    private let gutter: CGFloat = 56
    private let slot: TimeInterval = 30 * 60

    var body: some View {
        GeometryReader { geo in
            let dayWidth = max((geo.size.width - gutter - 8) / 7, 40)
            VStack(spacing: 0) {
                header(dayWidth: dayWidth)
                Theme.line.frame(height: 1)
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        grid(dayWidth: dayWidth)
                        // the now line alone redraws each minute, not the whole grid
                        .overlay(alignment: .topLeading) {
                            TimelineView(.everyMinute) { context in nowLine(dayWidth: dayWidth, now: context.date) }
                                .allowsHitTesting(false)
                        }
                        // one marker per hour, laid out (not offset) so scrollTo can find them
                        .background(alignment: .top) {
                            VStack(spacing: 0) {
                                ForEach(0..<24, id: \.self) { Color.clear.frame(height: hourHeight).id($0) }
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                    // opens at 8 AM; the next turn of the run loop, once the content is laid out
                    .onAppear { DispatchQueue.main.async { proxy.scrollTo(8, anchor: .top) } }
                }
            }
        }
    }

    private func header(dayWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: gutter, height: 0)
            ForEach(model.days, id: \.self) { day in
                let today = Calendar.current.isDateInToday(day)
                VStack(spacing: 2) {
                    Text(day.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                        .uiFont(11, weight: .semibold)
                        .foregroundStyle(today ? Theme.accent : Theme.muted)
                    Text(day.formatted(.dateTime.day()))
                        .uiFont(18, weight: today ? .bold : .regular)
                        .foregroundStyle(today ? Theme.accent : Theme.text)
                }
                .frame(width: dayWidth)
            }
        }
        .padding(.bottom, 6)
    }

    private func grid(dayWidth: CGFloat) -> some View {
        // a person whose calendar Kalendar can't read gets no column; the legend says so
        let shown = model.people.indices.map { ($0, model.schedules[model.people[$0].email.lowercased()]) }
            .filter { $0.1 != .unavailable }
        let columns = [model.mine] + shown.map { $0.1?.blocks ?? [] }
        let colors = [color(0)] + shown.map { color($0.0 + 1) }
        let busyOnly = [false] + shown.map { if case .busy = $0.1 { true } else { false } }
        let columnWidth = dayWidth / CGFloat(columns.count)
        return ZStack(alignment: .topLeading) {
            ForEach(0..<24, id: \.self) { hour in
                HStack(alignment: .top, spacing: 4) {
                    Text(hourLabel(hour)).uiFont(11).foregroundStyle(Theme.muted)
                        .frame(width: gutter - 8, alignment: .trailing)
                        .offset(y: -7)
                    Theme.line.frame(height: 1)
                }
                .frame(height: hourHeight, alignment: .top)
                .offset(y: CGFloat(hour) * hourHeight)
            }
            ForEach(Array(model.days.enumerated()), id: \.element) { dayIndex, day in
                let x = gutter + CGFloat(dayIndex) * dayWidth
                Theme.line.frame(width: 1, height: 24 * hourHeight).offset(x: x)
                ForEach(Array(columns.enumerated()), id: \.offset) { column, blocks in
                    let laid = Availability.lanes(blocks.compactMap { clip($0, to: day) })
                    ForEach(Array(laid.enumerated()), id: \.offset) { _, item in
                        let width = columnWidth / CGFloat(item.lanes)
                        // inset 1 pt on every side, so events side by side or back to back keep a gap
                        BlockView(block: item.block, color: colors[column], busyOnly: busyOnly[column])
                            .frame(width: max(width - 2, 2), height: max(y(item.block.end, in: day) - y(item.block.start, in: day) - 2, 12))
                            .offset(x: x + CGFloat(column) * columnWidth + CGFloat(item.lane) * width + 1,
                                    y: y(item.block.start, in: day) + 1)
                    }
                }
            }
            // last, so the span being chosen shows over the events it overlaps
            SlotHighlightView(highlight: highlight) { rect(for: $0, dayWidth: dayWidth).insetBy(dx: 1, dy: 0) }
        }
        .frame(width: gutter + 7 * dayWidth, height: 24 * hourHeight, alignment: .topLeading)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            // with the button down, a drag owns the highlight
            guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
            // only a new slot redraws, and only the highlight view reads `highlight`
            var span: Span?
            if case .active(let point) = phase { span = slot(at: point, dayWidth: dayWidth).map(defaultSpan) }
            if span != highlight.span { highlight.span = span }
        }
        // a click opens the form for the default duration; a drag, for the slots dragged across
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { drag in
                guard let span = span(of: drag, dayWidth: dayWidth) else { return }
                if span != highlight.span { highlight.span = span }
            }
            .onEnded { drag in
                guard let span = span(of: drag, dayWidth: dayWidth) else { return }
                highlight.span = span
                clicked = rect(for: span, dayWidth: dayWidth)
                model.openSlot(span.start, end: span.end)
            })
        .popover(isPresented: Binding(get: { model.newEvent != nil }, set: { shown in
                    // closing the form clears its span; the pointer's next move shows the slot under it
                    if !shown { model.newEvent = nil; highlight.span = nil }
                 }),
                 attachmentAnchor: .rect(.rect(clicked)), arrowEdge: .trailing) {
            if let form = model.newEvent {
                EventEditor(model: form, onAdd: model.addEvent).frame(width: 320)
            }
        }
    }

    @ViewBuilder
    private func nowLine(dayWidth: CGFloat, now: Date) -> some View {
        if let dayIndex = model.days.firstIndex(where: { Calendar.current.isDate(now, inSameDayAs: $0) }) {
            Theme.bad.frame(width: dayWidth, height: 2)
                .offset(x: gutter + CGFloat(dayIndex) * dayWidth, y: y(now, in: model.days[dayIndex]))
        }
    }

    /// The meeting a press or drag describes: from the slot pressed to the one under the pointer, in
    /// that day's column, either direction; the default duration while the pointer is in the slot
    /// pressed, so a click that jitters, or a drag brought back, isn't a 30-minute meeting.
    private func span(of drag: DragGesture.Value, dayWidth: CGFloat) -> Span? {
        guard let from = slot(at: drag.startLocation, dayWidth: dayWidth) else { return nil }
        // the pointer may leave the grid; it is held to the day's first and last slots
        let y = min(max(drag.location.y, 0), 24 * hourHeight - 1)
        guard let to = slot(at: CGPoint(x: drag.startLocation.x, y: y), dayWidth: dayWidth) else { return nil }
        guard to != from else { return defaultSpan(from) }
        let (first, last) = from.start <= to.start ? (from, to) : (to, from)
        return Span(day: from.day, start: first.start, end: last.start.addingTimeInterval(slot))
    }

    private func defaultSpan(_ slot: Slot) -> Span {
        Span(day: slot.day, start: slot.start,
             end: slot.start.addingTimeInterval(TimeInterval(Preferences.shared.defaultDuration * 60)))
    }

    private func rect(for span: Span, dayWidth: CGFloat) -> CGRect {
        let day = model.days[span.day]
        let top = y(span.start, in: day)
        return CGRect(x: gutter + CGFloat(span.day) * dayWidth, y: top, width: dayWidth, height: y(span.end, in: day) - top)
    }

    /// The 30-minute slot at `point`, by day column.
    private func slot(at point: CGPoint, dayWidth: CGFloat) -> Slot? {
        let day = Int((point.x - gutter) / dayWidth)
        guard point.x >= gutter, model.days.indices.contains(day) else { return nil }
        let seconds = Double(point.y / hourHeight) * 3600
        let snapped = (seconds / slot).rounded(.down) * slot
        guard snapped >= 0, snapped < 86400 else { return nil }
        // the clock time under the pointer, which on a daylight-saving day isn't midnight plus `snapped`
        let minutes = Int(snapped) / 60
        return Slot(day: day, start: Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0,
                                                           of: model.days[day]) ?? model.days[day])
    }

    /// The part of `block` inside `day`; nil when it doesn't touch the day.
    private func clip(_ block: Availability.Block, to day: Date) -> Availability.Block? {
        guard let next = Calendar.current.date(byAdding: .day, value: 1, to: day),
              block.end > day, block.start < next else { return nil }
        return Availability.Block(start: max(block.start, day), end: min(block.end, next), title: block.title)
    }

    /// Where `date`'s clock time falls in `day`'s 24 hour rows; the next midnight is the bottom. By
    /// clock time, so events after a daylight-saving change still line up with the hour labels.
    private func y(_ date: Date, in day: Date) -> CGFloat {
        let calendar = Calendar.current
        guard let next = calendar.date(byAdding: .day, value: 1, to: day), date < next else { return 24 * hourHeight }
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        return (CGFloat(c.hour ?? 0) + CGFloat(c.minute ?? 0) / 60 + CGFloat(c.second ?? 0) / 3600) * hourHeight
    }

    private func hourLabel(_ hour: Int) -> String {
        guard hour > 0, let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) else { return "" }
        return date.formatted(.dateTime.hour())
    }
}

/// A 30-minute slot in the week: the day's column and the start.
private struct Slot: Equatable {
    var day: Int
    var start: Date
}

/// A meeting's place in the week: the day's column, the start and the end.
private struct Span: Equatable {
    var day: Int
    var start: Date
    var end: Date
}

/// The span under the pointer (the default duration) or being dragged. Its own object, read only by
/// `SlotHighlightView`, so moving the pointer redraws the highlight and not the grid.
@Observable
private final class SlotHighlight {
    var span: Span?
}

private struct SlotHighlightView: View {
    let highlight: SlotHighlight
    let frame: (Span) -> CGRect

    var body: some View {
        if let span = highlight.span {
            let rect = frame(span)
            RoundedRectangle(cornerRadius: 4)
                .fill(Theme.accent.opacity(0.15))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.accent, lineWidth: 1))
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
        }
    }
}

/// One busy stretch: the title and start time when the calendar is shared, "Busy" otherwise.
private struct BlockView: View {
    let block: Availability.Block
    let color: Color
    let busyOnly: Bool

    private var times: String {
        "\(block.start.formatted(date: .omitted, time: .shortened)) – \(block.end.formatted(date: .omitted, time: .shortened))"
    }

    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 0) {
                Text(block.title ?? "Busy").uiFont(11, weight: .semibold).lineLimit(geo.size.height > 30 ? 2 : 1)
                // a narrow block has room only for the title
                if geo.size.width >= 70 && geo.size.height > 30 { Text(times).uiFont(10).lineLimit(1) }
            }
        }
        .foregroundStyle(busyOnly ? Theme.text : .white)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(busyOnly ? color.opacity(0.3) : color.opacity(0.9), in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(color, lineWidth: busyOnly ? 1 : 0))
        .clipped()
        .help("\(block.title ?? "Busy"), \(times)")
    }
}
