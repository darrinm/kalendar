// An event's form in a window (Meet With §21, the calendar window §22): an NSPopover at the pointer
// that saves on close, as the panel's detail popover does (§6), and may ask about a repeating event
// first (§8.1).
import AppKit
import SwiftUI

@MainActor
final class EventPopover: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?
    /// Saves the open form; false when the user cancelled the question, so it stays open.
    private var shouldClose: (() -> Bool)?
    private var onClose: (() -> Void)?

    /// The new event's form open now, while Add Event may wait for its Zoom meeting.
    private var newForm: EventEditorModel?

    /// An existing event's form, saved when it closes (§6).
    func showExisting(_ form: EventEditorModel, in window: NSWindow?) {
        show(EventEditor(model: form), in: window, shouldClose: { form.shouldClose() })
    }

    /// A new event's form. Add Event commits it (§5.1: after creating a chosen Zoom meeting), adds it
    /// and closes the form; a form closed or replaced meanwhile adds nothing. `onClose` runs when it
    /// closes either way.
    func showNew(_ form: EventEditorModel, in window: NSWindow?, onClose: (() -> Void)? = nil) {
        let editor = EventEditor(model: form, onAdd: { [weak self, weak form] in if let form { self?.add(form) } })
        if show(editor, in: window, onClose: onClose) { newForm = form }
    }

    private func add(_ form: EventEditorModel) {
        guard form.canAdd else { return }
        form.commit { [weak self] draft in
            guard let self, newForm === form else { return }
            form.writer.insert(draft)
            if Preferences.shared.playSounds { NSSound(named: "Pop")?.play() }
            dismiss()
        }
    }

    /// Shows `content` beside the pointer in `window`. An open form is saved and closed first; when
    /// that is cancelled, nothing opens and this returns false.
    @discardableResult
    private func show(_ content: some View, in window: NSWindow?, shouldClose: (() -> Bool)? = nil,
                      onClose: (() -> Void)? = nil) -> Bool {
        guard let window, let view = window.contentView, close() else { return false }
        let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = PopoverController.hosting(AnyView(content), width: 320)
        popover.show(relativeTo: NSRect(origin: point, size: CGSize(width: 1, height: 1)), of: view, preferredEdge: .maxX)
        PopoverController.paintFrame(of: popover)
        self.popover = popover
        self.shouldClose = shouldClose
        self.onClose = onClose
        return true
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
    private func dismiss() {
        guard let popover else { return }
        let closed = onClose
        self.popover = nil
        shouldClose = nil
        onClose = nil
        newForm = nil
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
