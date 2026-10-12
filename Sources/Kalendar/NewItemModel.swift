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

    /// The live form; nil while the input is empty.
    private(set) var form: EventEditorModel?
    private(set) var trigger: SuggestionTrigger?
    private(set) var suggestions: [Suggestion] = []
    var selected = 0
    /// Double-clicking a day pre-dates the entry (§4.2).
    var defaultDay: Date?

    // choices made by accepting a suggestion: their tokens leave the text, so the parse can't hold them
    @ObservationIgnored private var chosenCalendar: CalendarInfo?
    @ObservationIgnored private var chosenLocation: String?
    @ObservationIgnored private var chosenInvitees: [Contact] = []
    @ObservationIgnored private var dismissedTrigger: String?
    @ObservationIgnored private let places = PlaceSearch()
    /// `with <name>` lookups for this entry, so each keystroke queries the cache once, not twice.
    @ObservationIgnored private var contactEmails: [String: String?] = [:]

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
        let firstAccount = accounts.accounts.first?.email
        return writable.first { $0.account == firstAccount && $0.primary } ?? writable.first
    }

    func update(input: String) {
        guard !input.trimmingCharacters(in: .whitespaces).isEmpty else {
            reset()
            return
        }
        let parser = NLParser(defaultDay: defaultDay) { [weak self] in self?.contactEmail(named: $0) }
        let parsed = parser.parse(input)
        guard let calendar = calendar(for: parsed.calendarQuery) else { return }
        var draft = EventDraft(parsed: parsed, account: calendar.account, calendarId: calendar.id)
        if let chosenLocation { draft.location = chosenLocation }
        // each guest once, and never the organizer again
        var seen: Set<String> = [calendar.account.lowercased()]
        let emails = (parsed.invitees + chosenInvitees.map(\.email)).filter { seen.insert($0.lowercased()).inserted }
        if !emails.isEmpty {
            // the organizer is listed with the guests, as Google does
            draft.attendees = [Attendee(email: calendar.account, displayName: nil, isSelf: true, organizer: true,
                                        optional: false, responseStatus: "accepted")]
                + emails.map { email in
                    Attendee(email: email, displayName: chosenInvitees.first { $0.email == email }?.name, isSelf: false,
                             organizer: false, optional: false, responseStatus: "needsAction")
                }
        }
        if let form { form.follow(draft) } else { form = EventEditorModel(newDraft: draft, agenda: agenda, writer: writer) }

        let previous = trigger
        trigger = parsed.trigger
        if let t = trigger, "\(t.kind)|\(t.query)" == dismissedTrigger { trigger = nil }
        // a new or narrowed list starts at its first row
        if trigger?.kind != previous?.kind || trigger?.query != previous?.query { selected = 0 }
        if trigger?.kind == .location { places.query = trigger!.query } else { places.query = "" }
        refreshSuggestions()
    }

    private func contactEmail(named name: String) -> String? {
        if let cached = contactEmails[name] { return cached }
        let email = try? agenda.cache.uniqueContactEmail(named: name)
        contactEmails[name] = email
        return email
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
            suggestions = q.isEmpty ? [] : ((try? agenda.cache.contacts(matching: trigger.query)) ?? []).map(Suggestion.contact)
        case .location:
            let recent = ((try? agenda.cache.recentLocations(matching: trigger.query)) ?? [])
                .map { Suggestion.place(title: $0, subtitle: "") }
            suggestions = Array((recent + places.results.map { Suggestion.place(title: $0.title, subtitle: $0.subtitle) }).prefix(8))
        }
        selected = min(selected, max(suggestions.count - 1, 0))
    }

    // MARK: Suggestions

    /// Esc on an open list: hide it until the token changes.
    func dismissSuggestions() {
        if let t = trigger { dismissedTrigger = "\(t.kind)|\(t.query)" }
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
        guard let form, !form.draft.summary.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        form.add()
        if UserDefaults.standard.object(forKey: "playSounds") as? Bool ?? true { NSSound(named: "Pop")?.play() }
        reset()
        defaultDay = nil
        return true
    }

    /// Whether cancelling should ask first (§8.3): the form was edited by hand, not just typed into.
    var needsDiscardConfirmation: Bool { form?.hasChanges ?? false }

    func reset() {
        form = nil
        trigger = nil
        suggestions = []
        chosenCalendar = nil
        chosenLocation = nil
        chosenInvitees = []
        dismissedTrigger = nil
        contactEmails = [:]
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
                completer.cancel()
            } else {
                completer.queryFragment = query
            }
        }
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        MainActor.assumeIsolated {
            self.results = Array(results.prefix(6))
            onResults()
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {}
}
