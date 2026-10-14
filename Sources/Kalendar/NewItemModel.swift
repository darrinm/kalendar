// The new-item flow (§5): the input is parsed on every keystroke into a live form, with a
// suggestion list for the token being typed (`/calendar`, `with person`, `at place`).
import AppKit
import KalendarCore
import MapKit
import Observation

enum Suggestion: Identifiable {
    case calendar(CalendarInfo)
    case contact(Contact)
    case place(title: String, subtitle: String)

    var id: String {
        switch self {
        case .calendar(let c): "c|\(c.key)"
        case .contact(let c): "p|\(c.email)"
        case .place(let title, let subtitle): "l|\(title)|\(subtitle)"
        }
    }
}

@MainActor
@Observable
final class NewItemModel {
    let agenda: AgendaModel
    let writer: EventWriter
    let accounts: AccountStore

    /// The live form; nil while the input is empty or the entry is a task.
    private(set) var form: EventEditorModel?
    /// The live task form (§5.1), when the input has a task prefix or ▣ | ✓ chose a task.
    private(set) var taskForm: TaskEditorModel?
    /// The ▣ | ✓ choice; nil follows the input's prefix.
    @ObservationIgnored private var chosenKind: Bool?
    @ObservationIgnored private var input = ""
    private(set) var trigger: SuggestionTrigger?
    private(set) var suggestions: [Suggestion] = []
    var selected = 0
    /// Double-clicking a day pre-dates the entry (§4.2).
    var defaultDay: Date?

    // choices made by accepting a suggestion: their tokens leave the text, so the parse can't hold them
    @ObservationIgnored private var chosenCalendar: CalendarInfo?
    @ObservationIgnored private var chosenLocation: String?
    @ObservationIgnored private var chosenInvitees: [Contact] = []
    /// The suggestion list Esc hid; it stays hidden until the token changes.
    @ObservationIgnored private var dismissedTrigger: (kind: SuggestionTrigger.Kind, query: String)?
    @ObservationIgnored private let places = PlaceSearch()
    /// Everyone a `with` or invitee suggestion can offer, loaded once per entry (§18.4).
    @ObservationIgnored private var loadedContacts: [Contact]?
    /// Recent locations for the current `at` query, kept while Apple Maps results arrive.
    @ObservationIgnored private var recent: (query: String, locations: [String])?

    init(agenda: AgendaModel, writer: EventWriter, accounts: AccountStore) {
        self.agenda = agenda
        self.writer = writer
        self.accounts = accounts
        places.onResults = { [weak self] in self?.refreshSuggestions() }
    }

    var showsSuggestions: Bool { !suggestions.isEmpty }

    // MARK: Parsing

    /// The calendar for a new event: the one picked with `/`, else the first account's primary.
    private func calendar(for query: String?) -> CalendarInfo? {
        if let chosenCalendar { return chosenCalendar }
        let writable = agenda.calendars.filter(\.isWritable)
        if let q = query?.lowercased(), !q.isEmpty,
           let match = writable.first(where: { $0.summary.lowercased().hasPrefix(q) }) {
            return match
        }
        return agenda.defaultCalendar(account: accounts.accounts.first?.email)
    }

    func update(input: String) {
        self.input = input
        guard !input.trimmingCharacters(in: .whitespaces).isEmpty else {
            reset()
            return
        }
        let prefs = Preferences.shared
        let parser = NLParser(calendar: prefs.calendar, defaultDuration: TimeInterval(prefs.defaultDuration * 60),
                              defaultDay: defaultDay) { [weak self] in self?.contacts.uniqueEmail(named: $0) }
        let parsed = parser.parse(input)
        // without a task list there is nowhere to add a task, so the input stays an event
        if chosenKind ?? parsed.isTask, !agenda.taskLists.isEmpty {
            updateTask(parsed)
            return
        }
        taskForm = nil
        guard let calendar = calendar(for: parsed.calendarQuery) else { return }
        var draft = EventDraft(parsed: parsed, account: calendar.account, calendarId: calendar.id)
        if let chosenLocation { draft.location = chosenLocation }
        draft.invite((parsed.invitees + chosenInvitees.map(\.email)).map { email in
            (email, chosenInvitees.first { $0.email == email }?.name)
        })
        if let form { form.follow(draft) } else { form = EventEditorModel(newDraft: draft, agenda: agenda, writer: writer) }

        let previous = trigger
        trigger = parsed.trigger
        if let t = trigger, let d = dismissedTrigger, d.kind == t.kind, d.query == t.query { trigger = nil }
        // a new or narrowed list starts at its first row
        if trigger?.kind != previous?.kind || trigger?.query != previous?.query { selected = 0 }
        if trigger?.kind == .location { places.query = trigger!.query } else { places.query = "" }
        refreshSuggestions()
    }

    /// The task form for parsed input: due on the parsed day; the list named after `/`, else the
    /// first account's first list.
    private func updateTask(_ parsed: ParsedItem) {
        form = nil
        trigger = nil
        suggestions = []
        let lists = agenda.taskLists
        let q = parsed.calendarQuery?.lowercased() ?? ""
        guard let list = (q.isEmpty ? nil : lists.first { $0.title.lowercased().hasPrefix(q) })
                ?? Preferences.shared.defaultTaskList.flatMap(agenda.taskList(forKey:))
                ?? agenda.defaultTaskList(account: accounts.accounts.first?.email) else { return }
        let task = TaskItem(account: list.account, listId: list.id, id: "", title: parsed.title,
                            due: parsed.hasDate || defaultDay != nil ? Calendar.current.startOfDay(for: parsed.start) : nil)
        if let taskForm {
            taskForm.follow(task, timeIgnored: parsed.hasTime)
        } else {
            taskForm = TaskEditorModel(task: task, isNew: true, timeIgnored: parsed.hasTime, agenda: agenda, writer: writer)
        }
    }

    /// ▣ | ✓ (§5.1).
    func setKind(task: Bool) {
        chosenKind = task
        update(input: input)
    }

    private var contacts: [Contact] {
        if let loadedContacts { return loadedContacts }
        let all = (try? agenda.cache.allContacts()) ?? []
        loadedContacts = all
        return all
    }

    private func recentLocations(_ query: String) -> [String] {
        if let recent, recent.query == query { return recent.locations }
        let locations = (try? agenda.cache.recentLocations(matching: query)) ?? []
        recent = (query, locations)
        return locations
    }

    private func refreshSuggestions() {
        guard let trigger else {
            suggestions = []
            return
        }
        let q = trigger.query.lowercased()
        switch trigger.kind {
        case .calendar:
            suggestions = agenda.calendars
                .filter { $0.isWritable && (q.isEmpty || $0.summary.lowercased().hasPrefix(q)) }
                .map(Suggestion.calendar)
        case .contact:
            suggestions = contacts.matching(trigger.query).map(Suggestion.contact)
        case .location:
            let recent = recentLocations(trigger.query).map { Suggestion.place(title: $0, subtitle: "") }
            // Apple Maps ranks by relevance to the region; places whose name starts with what was
            // typed come first ("Tar": Target before Pike Place Market), otherwise in its order
            let named = places.results.filter { $0.title.lowercased().hasPrefix(q) }
            let other = places.results.filter { !$0.title.lowercased().hasPrefix(q) }
            let maps = (named + other).map { Suggestion.place(title: $0.title, subtitle: $0.subtitle) }
            suggestions = Array((recent + maps).prefix(8))
        }
        selected = min(selected, max(suggestions.count - 1, 0))
    }

    // MARK: Suggestions

    /// Esc on an open list: hide it until the token changes.
    func dismissSuggestions() {
        if let t = trigger { dismissedTrigger = (t.kind, t.query) }
        trigger = nil
        suggestions = []
    }

    func moveSelection(by delta: Int) {
        guard !suggestions.isEmpty else { return }
        selected = (selected + delta + suggestions.count) % suggestions.count
    }

    /// Accepts a suggestion (§5.2): its token leaves the input and the choice goes into the form.
    /// Returns the new input text.
    func accept(_ index: Int? = nil, in input: String) -> String {
        guard let trigger, suggestions.indices.contains(index ?? selected) else { return input }
        switch suggestions[index ?? selected] {
        case .calendar(let c): chosenCalendar = c
        case .contact(let c): chosenInvitees.append(c)
        case .place(let title, let subtitle): chosenLocation = subtitle.isEmpty ? title : "\(title), \(subtitle)"
        }
        var text = input
        text.removeSubrange(trigger.range)
        text = text.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces) + " "
        self.trigger = nil
        suggestions = []
        return text
    }

    // MARK: Commit

    /// Adds the event (§5.4). Returns false when there is nothing to add.
    func add() -> Bool {
        if let taskForm, taskForm.canAdd {
            let t = taskForm.draft
            writer.insertTask(title: t.title.trimmingCharacters(in: .whitespaces), notes: t.notes, due: t.due,
                              account: t.account, listId: t.listId)
        } else if let form, form.canAdd {
            writer.insert(form.draft)
        } else {
            return false
        }
        if Preferences.shared.playSounds { NSSound(named: "Pop")?.play() }
        reset()
        defaultDay = nil
        return true
    }

    /// Whether cancelling should ask first (§8.3): the form was edited by hand, not just typed into.
    var needsDiscardConfirmation: Bool { form?.hasChanges ?? taskForm?.hasChanges ?? false }

    func reset() {
        form = nil
        taskForm = nil
        chosenKind = nil
        trigger = nil
        suggestions = []
        chosenCalendar = nil
        chosenLocation = nil
        chosenInvitees = []
        dismissedTrigger = nil
        loadedContacts = nil
        recent = nil
        places.query = ""
    }
}

/// Apple Maps place search for `at …` (§5.2), via MKLocalSearchCompleter.
@MainActor
final class PlaceSearch: NSObject, MKLocalSearchCompleterDelegate {
    private let completer = MKLocalSearchCompleter()
    private(set) var results: [MKLocalSearchCompletion] = []
    var onResults: () -> Void = {}

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            if query.isEmpty {
                results = []
                // the completer ignores a fragment equal to its current one, so retyping the last
                // query after clearing would otherwise show no results
                completer.queryFragment = ""
                completer.cancel()
            } else {
                completer.queryFragment = query
            }
        }
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        MainActor.assumeIsolated {
            // a reply to a query made before the field was cleared
            guard !query.isEmpty else { return }
            self.results = Array(results.prefix(6))
            onResults()
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {}
}
