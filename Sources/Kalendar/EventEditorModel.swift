// The detail popover's state (§6): the event, its draft, and what closing the popover does with
// the edits (§8.1). The new-item form (§5) uses it too, for an event that doesn't exist yet.
import AppKit
import KalendarCore
import Observation

@MainActor
@Observable
final class EventEditorModel {
    let event: EventInstance
    let agenda: AgendaModel
    let writer: EventWriter
    private(set) var original: EventDraft
    var draft: EventDraft
    /// The master event, loaded for a recurring occurrence (rule, times, etag).
    private(set) var series: EventWriter.Series?
    var expanded = false
    /// The new-item form: `draft` follows the parsed input until it is added (§5).
    let isNew: Bool

    init(event: EventInstance, agenda: AgendaModel, writer: EventWriter) {
        isNew = false
        self.event = event
        self.agenda = agenda
        self.writer = writer
        let draft = EventDraft(event, recurrence: nil)
        original = draft
        self.draft = draft
        writer.clearError()
        // the series' rule shows only in the editable fields; an invitation hides Repeat
        if event.recurringEventId != nil && !event.isInvitation {
            Task { await loadSeries() }
        }
    }

    /// The new-item form for a draft parsed from the input.
    init(newDraft draft: EventDraft, agenda: AgendaModel, writer: EventWriter) {
        isNew = true
        event = EventInstance(placeholder: "", draft: draft)
        self.agenda = agenda
        self.writer = writer
        original = draft
        self.draft = draft
        writer.clearError()
    }

    /// The input changed: fields the user hasn't edited by hand take the new parse (§5.2).
    func follow(_ parsed: EventDraft) {
        draft = draft.following(parsed, previousParse: original)
        original = parsed
    }

    /// Adds the new event (§5.4).
    func add() {
        writer.insert(draft)
    }

    private func loadSeries() async {
        guard let series = await writer.series(of: event) else { return }
        self.series = series
        // the rule arrives after the popover opened; fold it into both copies so it isn't an edit
        let edited = draft != original
        original.recurrence = series.rule
        if edited { draft.recurrence = series.rule } else { draft = original }
    }

    /// The user's copy of someone else's invitation: Google lets an attendee change only their own
    /// alerts, color and busy/free. Everything else is read-only (§6).
    var isInvitation: Bool { event.isInvitation }
    var isRecurring: Bool { event.recurringEventId != nil }
    var hasChanges: Bool { draft != original }

    var writableCalendars: [CalendarInfo] {
        agenda.calendars.filter { c in
            (c.accessRole == "owner" || c.accessRole == "writer")
                && (c.account == event.account || !isInvitation)
        }
    }

    // MARK: Closing

    /// Called when the popover is about to close. Saves the edits; for a recurring event asks
    /// which occurrences they apply to. Returns false to keep the popover open (Cancel).
    func shouldClose() -> Bool {
        guard hasChanges else { return true }
        // a repeat change belongs to the whole series, so it needs no question
        let asked = isRecurring && draft.recurrence != original.recurrence ? .series : Dialogs.scope(for: event)
        guard let scope = asked else { return false }
        writer.save(event, original: original, draft: draft, scope: scope, series: series)
        return true
    }

    /// Accept / Decline / Maybe from the popover's button row.
    func respond(_ response: String) {
        guard let scope = Dialogs.scope(for: event) else { return }
        writer.respond(event, response: response, scope: scope)
    }

    // MARK: Field helpers

    /// The end date the user sees: for an all-day event, the last day rather than the exclusive end.
    var displayedEnd: Date {
        get { draft.allDay ? Calendar.current.date(byAdding: .day, value: -1, to: draft.end)! : draft.end }
        set {
            let cal = Calendar.current
            draft.end = draft.allDay ? cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: newValue))! : newValue
            if draft.end <= draft.start { draft.start = draft.allDay ? cal.date(byAdding: .day, value: -1, to: draft.end)! : draft.end.addingTimeInterval(-3600) }
        }
    }

    /// Moving the start keeps the duration, as calendar apps do.
    func setStart(_ start: Date) {
        let duration = draft.end.timeIntervalSince(draft.start)
        draft.start = draft.allDay ? Calendar.current.startOfDay(for: start) : start
        draft.end = draft.start.addingTimeInterval(max(duration, draft.allDay ? 86400 : 0))
    }

    func setAllDay(_ allDay: Bool) {
        let cal = Calendar.current
        draft.allDay = allDay
        if allDay {
            draft.start = cal.startOfDay(for: draft.start)
            draft.end = max(cal.startOfDay(for: draft.end), cal.date(byAdding: .day, value: 1, to: draft.start)!)
        } else {
            // a fresh timed slot: 9 AM for an hour, the default duration (§2)
            draft.start = cal.date(bySettingHour: 9, minute: 0, second: 0, of: draft.start)!
            draft.end = draft.start.addingTimeInterval(3600)
        }
    }

    /// The popup alerts shown: the event's own, or the calendar's defaults when it uses them.
    var effectiveAlerts: [Int] {
        draft.reminders.useDefault
            ? (agenda.calendar(forKey: draft.calendarKey)?.defaultReminders ?? [])
            : draft.reminders.minutes
    }

    /// Editing any alert turns the calendar defaults into the event's own list.
    func setAlerts(_ minutes: [Int]) {
        draft.reminders = Reminders(useDefault: false, minutes: Array(minutes.prefix(5)))
    }
}
