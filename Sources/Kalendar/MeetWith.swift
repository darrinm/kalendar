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
    private let popover = EventPopover()

    init(model: MeetWithModel) {
        self.model = model
        model.showForm = { [weak self, weak model] form, closed in
            self?.popover.show(EventEditor(model: form, onAdd: { model?.addEvent(form) }), in: self?.window, onClose: closed)
        }
        model.closeForm = { [weak self] in self?.popover.dismiss() }
    }

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
    @ObservationIgnored private var newEvent: EventEditorModel?
    /// Shows a new-event form beside the pointer; the closure runs when it closes. Set by the window
    /// controller, with `closeForm`.
    @ObservationIgnored var showForm: (EventEditorModel, @escaping () -> Void) -> Void = { _, _ in }
    @ObservationIgnored var closeForm: () -> Void = {}
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
    /// account in the first person's domain. `done` runs when the form closes.
    func openSlot(_ start: Date, end: Date, done: @escaping () -> Void) {
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
        let form = EventEditorModel(newDraft: draft, agenda: agenda, writer: writer)
        newEvent = form
        showForm(form) { [weak self] in
            if self?.newEvent === form { self?.newEvent = nil }
            done()
        }
    }

    func addEvent(_ form: EventEditorModel) {
        guard form.canAdd else { return }
        // a form closed or replaced while its Zoom meeting was created adds nothing
        form.commit { [weak self] draft in
            guard let self, newEvent === form else { return }
            writer.insert(draft)
            if Preferences.shared.playSounds { NSSound(named: "Pop")?.play() }
            closeForm()
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
            PeopleGrid(model: model)
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

/// The week grid: the user's events, then each person's whose calendar Kalendar can read; a person
/// whose calendar it can't gets no column, and the legend says so.
private struct PeopleGrid: View {
    let model: MeetWithModel

    var body: some View {
        let shown = model.people.indices.map { ($0, model.schedules[model.people[$0].email.lowercased()]) }
            .filter { $0.1 != .unavailable }
        let mine = model.mine.enumerated().map { GridBlock(id: "me\($0.offset)", start: $0.element.start, end: $0.element.end,
                                                           title: $0.element.title, color: color(0)) }
        let theirs = shown.map { index, schedule in
            let busyOnly = if case .busy = schedule { true } else { false }
            return (schedule?.blocks ?? []).enumerated().map {
                GridBlock(id: "\(index)-\($0.offset)", start: $0.element.start, end: $0.element.end, title: $0.element.title,
                          color: color(index + 1), outlined: busyOnly)
            }
        }
        TimeGrid(days: model.days, columns: [mine] + theirs) { start, end, done in
            model.openSlot(start, end: end, done: done)
        }
    }
}

