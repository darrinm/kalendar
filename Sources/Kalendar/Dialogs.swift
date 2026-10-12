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
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .occurrence
        case .alertSecondButtonReturn: return .series
        default: return nil
        }
    }
}
