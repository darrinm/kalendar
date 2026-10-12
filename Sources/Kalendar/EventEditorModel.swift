// The detail popover's state (§6): the event, its draft, and what closing the popover does with
// the edits (§8.1).
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

    init(event: EventInstance, agenda: AgendaModel, writer: EventWriter) {
        self.event = event
        self.agenda = agenda
        self.writer = writer
        let draft = EventDraft(event, recurrence: nil)
        original = draft
        self.draft = draft
        writer.clearError()
        if event.recurringEventId != nil {
            Task { await loadSeries() }
        }
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
    var isInvitation: Bool { !event.organizerSelf && !event.attendees.isEmpty }
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
        var scope = EventWriter.Scope.occurrence
        if isRecurring {
            // a repeat change belongs to the whole series, so it needs no question
            if draft.recurrence != original.recurrence {
                scope = .series
            } else {
                guard let answer = Dialogs.recurringScope() else { return false }
                scope = answer
            }
        }
        writer.save(event, original: original, draft: draft, scope: scope, series: series)
        return true
    }

    /// Accept / Decline / Maybe from the popover's button row.
    func respond(_ response: String) {
        var scope = EventWriter.Scope.occurrence
        if isRecurring {
            guard let answer = Dialogs.recurringScope() else { return }
            scope = answer
        }
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
            ? (agenda.calendars.first { $0.key == draft.calendarKey }?.defaultReminders ?? [])
            : draft.reminders.minutes
    }

    /// Editing any alert turns the calendar defaults into the event's own list.
    func setAlerts(_ minutes: [Int]) {
        draft.reminders = Reminders(useDefault: false, minutes: Array(minutes.prefix(5)))
    }
}
