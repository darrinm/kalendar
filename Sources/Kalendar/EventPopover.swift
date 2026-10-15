// An event's form in a window (Meet With §21, the calendar window §22): an NSPopover at the pointer
// that saves on close, as the panel's detail popover does (§6), and may ask about a repeating event
// first (§8.1).
import AppKit
import KalendarCore
import SwiftUI

@MainActor
final class EventPopover: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?
    /// Saves the open form; false when the user cancelled the question, so it stays open.
    private var shouldClose: (() -> Bool)?
    private var onClose: (() -> Void)?

    /// Shows `content` beside the pointer in `window`. An open form is saved and closed first; when
    /// that is cancelled, nothing opens.
    func show(_ content: some View, in window: NSWindow?, shouldClose: (() -> Bool)? = nil, onClose: (() -> Void)? = nil) {
        guard let view = window?.contentView, close() else { return }
        let point = view.convert(window!.mouseLocationOutsideOfEventStream, from: nil)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = PopoverController.hosting(AnyView(content), width: 320)
        popover.show(relativeTo: NSRect(origin: point, size: CGSize(width: 1, height: 1)), of: view, preferredEdge: .maxX)
        PopoverController.paintFrame(of: popover)
        self.popover = popover
        self.shouldClose = shouldClose
        self.onClose = onClose
    }

    /// Saves and closes the open form; false when the user cancelled the question.
    @discardableResult
    func close() -> Bool {
        guard popover != nil else { return true }
        guard shouldClose?() ?? true else { return false }
        dismiss()
        return true
    }

    /// Closes the form without saving: a new event that was just added. Its `onClose` runs now, not
    /// when the close animation ends, so it can't run after the next form has opened.
    func dismiss() {
        guard let popover else { return }
        let closed = onClose
        self.popover = nil
        shouldClose = nil
        onClose = nil
        popover.close()
        closed?()
    }

    /// A dialog (§8) taking key must not close the form: Cancel returns to it.
    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        if NSApp.modalWindow != nil { return false }
        guard shouldClose?() ?? true else { return false }
        shouldClose = nil
        return true
    }

    /// A transient close (a click outside). A popover already dismissed, or replaced by the next
    /// form, has run its `onClose`.
    func popoverDidClose(_ notification: Notification) {
        guard (notification.object as? NSPopover) === popover else { return }
        dismiss()
    }
}

extension EventDraft {
    /// A new timed event's draft for [start, end) on `calendar`: untitled, busy, with the
    /// calendar's default alerts.
    static func timed(on calendar: CalendarInfo, start: Date, end: Date) -> EventDraft {
        var draft = EventDraft(parsed: NLParser().parse(""), account: calendar.account, calendarId: calendar.id)
        draft.summary = ""
        // the empty parse is all-day
        draft.allDay = false
        draft.busy = true
        draft.reminders = Reminders()
        draft.start = start
        draft.end = end
        return draft
    }
}
