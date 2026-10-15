// Modal questions (§8.1).
import AppKit
import KalendarCore

@MainActor
enum Dialogs {
    /// The scope of a write to `event`: `.occurrence` for a one-off event, the user's answer for a
    /// recurring one. nil means Cancel.
    static func scope(for event: EventInstance) -> EventWriter.Scope? {
        event.recurringEventId == nil ? .occurrence : recurringScope()
    }

    /// "You're responding to a repeating event." Only This Event / All / Cancel. nil means Cancel.
    static func recurringScope() -> EventWriter.Scope? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "You're responding to a repeating event."
        alert.informativeText = "Do you want to respond to only this occurrence of the event, or all occurrences?"
        alert.addButton(withTitle: "Only This Event")
        alert.addButton(withTitle: "All")
        alert.addButton(withTitle: "Cancel")
        accent(alert)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .occurrence
        case .alertSecondButtonReturn: return .series
        default: return nil
        }
    }

    /// The question for an edit from `original` to `draft`. Nobody is emailed, so nothing is asked,
    /// for a change to only the user's own alerts, color or busy/free, or for a move to another
    /// account's calendar (an insert and a delete without emails, EventWriter.enqueueMove).
    static func notifyGuests(about event: EventInstance, from original: EventDraft, to draft: EventDraft) -> Bool? {
        guard draft.changesWhatGuestsSee(from: original), draft.account == original.account else { return false }
        return notifyGuests(about: event, editedTo: draft)
    }

    /// "Send update emails to guests?" before changing or deleting an event the user organizes that
    /// has guests, as Google Calendar asks. True for Send, false for Don't Send, nil for Cancel. An
    /// event Google wouldn't email anyone about needs no question: true. `draft` is the edit, which
    /// may add the first guests.
    static func notifyGuests(about event: EventInstance, editedTo draft: EventDraft? = nil, deleting: Bool = false) -> Bool? {
        guard EventWriter.emailsGuests(event, editedTo: draft) else { return true }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = deleting ? "Send cancellation emails to guests?" : "Send update emails to guests?"
        alert.informativeText = deleting
            ? "Google can email the guests of “\(event.summary)” that it's cancelled."
            : "Google can email the guests of “\(event.summary)” about the change."
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Don't Send")
        alert.addButton(withTitle: "Cancel")
        accent(alert)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return true
        case .alertSecondButtonReturn: return false
        default: return nil
        }
    }

    /// §8.3: "You're about to discard this item." Returns true for Discard.
    static func confirmDiscard() -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "You're about to discard this item."
        alert.informativeText = "Are you sure you want to close and discard your information? You can't undo this action."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        accent(alert)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// An error from a sign-in or another action the user started.
    static func error(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        accent(alert)
        alert.runModal()
    }

    /// The default button in Kalendar's accent (§8), not the system accent color.
    private static func accent(_ alert: NSAlert) {
        alert.buttons.first?.bezelColor = Theme.nsAccent
    }
}
