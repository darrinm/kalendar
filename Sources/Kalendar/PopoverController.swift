// The Mini Window: a transient NSPopover anchored to the status item (§4), plus the popovers that
// open beside it: the event detail (§6) and Go to Date.
//
// Those are shown relative to a view *inside* the main popover, which makes them child popovers:
// AppKit keeps the parent open while the user clicks in the child, and closes the child when the
// parent closes (spec §13).
import AppKit
import KalendarCore
import SwiftUI

@MainActor
final class PopoverController: NSObject, NSPopoverDelegate {
    static let size = NSSize(width: 320, height: 600)

    private let popover = NSPopover()
    private var detail: NSPopover?
    /// The status item button the popover is shown from.
    private weak var anchor: NSStatusBarButton?
    private let model: PopoverModel
    private var keyMonitor: Any?
    /// Called each time the popover opens; the app syncs then (§18.3).
    var onOpen: () -> Void = {}

    init(model: PopoverModel) {
        self.model = model
        super.init()
        popover.behavior = .transient
        popover.contentSize = Self.size
        popover.delegate = self
        model.close = { [weak self] in self?.close() }
        model.showChild = { [weak self] view, content, width, edge, shouldClose in
            self?.showChild(relativeTo: view, content: content, width: width, edge: edge, shouldClose: shouldClose) ?? false
        }
        model.contentView = { [weak self] in self?.popover.contentViewController?.view }
        popover.contentViewController = NSHostingController(rootView: PopoverRoot(model: model))
    }

    var isShown: Bool { popover.isShown }

    func toggle(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            close()
            return
        }
        // An accessory app is not active until told to be; without this the text field cannot
        // become first responder when the popover opens from the global hotkey.
        NSApp.activate(ignoringOtherApps: true)
        anchor = button
        model.willOpen()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        Self.paintFrame(of: popover)
        popover.contentViewController?.view.window?.makeKey()
        model.focusInput()
        installKeyMonitor()
        onOpen()
    }

    func close() {
        popover.performClose(nil)
    }

    /// The open child popover's save-on-close, if it is an event's or a task's detail popover.
    private var shouldClose: (() -> Bool)?

    /// Closes the open child popover, saving an event's edits first. False when the user cancelled
    /// the recurring-event question (§8.1), so everything stays open.
    private func closeChild() -> Bool {
        if let shouldClose, !shouldClose() { return false }
        dismissChild()
        return true
    }

    /// Closes the child popover without asking; any unsaved edits are dropped.
    private func dismissChild() {
        shouldClose = nil
        detail?.close()
        detail = nil
    }

    @discardableResult
    private func showChild(relativeTo view: NSView, content: AnyView, width: CGFloat, edge: NSRectEdge,
                           shouldClose: (() -> Bool)?) -> Bool {
        guard closeChild() else { return false }
        let child = NSPopover()
        child.behavior = .transient
        child.delegate = self
        child.contentViewController = NSHostingController(rootView: content.frame(width: width))
        // AppKit flips to the opposite edge when there is no room
        child.show(relativeTo: view.bounds, of: view, preferredEdge: edge)
        Self.paintFrame(of: child)
        detail = child
        self.shouldClose = shouldClose
        return true
    }

    /// NSPopover draws its own frame, arrow included, in the system popover material. Putting a
    /// view in the theme background behind the content view recolors the whole shape, so the arrow
    /// matches the content instead of showing the material.
    private static func paintFrame(of popover: NSPopover) {
        guard let frame = popover.contentViewController?.view.window?.contentView?.superview,
              !frame.subviews.contains(where: { $0 is PopoverBackgroundView }) else { return }
        let background = PopoverBackgroundView(frame: frame.bounds)
        background.autoresizingMask = [.width, .height]
        frame.addSubview(background, positioned: .below, relativeTo: nil)
    }

    /// A transient popover closes on mouse-down outside itself. For a mouse-down on the status item,
    /// stay open: the item's action fires on mouse-up and `toggle` closes the popover then. Closing
    /// here as well would let that mouse-up reopen it.
    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        // the detail popover saves on close (§6) and may ask about a recurring event first
        if popover === detail {
            guard shouldClose?() ?? true else { return false }
            shouldClose = nil
            return true
        }
        guard popover === self.popover else { return true }
        if let window = anchor?.window, let event = NSApp.currentEvent, event.type == .leftMouseDown,
           event.window === window {
            return false
        }
        return closeChild()
    }

    func popoverDidClose(_ notification: Notification) {
        if (notification.object as? NSPopover) === detail {
            detail = nil
            model.agenda.selectedEvent = nil
        }
        if (notification.object as? NSPopover) === popover {
            // normally closeChild already ran in popoverShouldClose; if the main popover closed some
            // other way, the detail must not outlive it, even when its save was cancelled
            if !closeChild() { dismissChild() }
            model.agenda.isVisible = false
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
    }

    /// Keyboard shortcuts (§11) that the text field would otherwise consume. Arrow keys navigate only
    /// while the input is empty, so they still move the caret in typed text.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === popover.contentViewController?.view.window else { return event }
            return model.handleKey(event) ? nil : event
        }
    }
}

/// State and callbacks the SwiftUI content needs from the AppKit shell.
@MainActor
@Observable
final class PopoverModel {
    let accounts: AccountStore
    let agenda: AgendaModel
    let signIn: (String?) -> Void
    let showSettings: () -> Void
    let refresh: () -> Void
    let writer: EventWriter
    let newItem: NewItemModel
    /// The input row's text; every change re-parses the new-item form (§5).
    var input = "" { didSet { if input != oldValue { newItem.update(input: input) } } }
    /// Bumped to ask the input field to take focus.
    var focusRequest = 0
    @ObservationIgnored var close: () -> Void = {}
    /// Shows a popover beside the Mini Window; false when the open one refused to close.
    @ObservationIgnored var showChild: (NSView, AnyView, CGFloat, NSRectEdge, (() -> Bool)?) -> Bool = { _, _, _, _, _ in false }
    @ObservationIgnored var contentView: () -> NSView? = { nil }

    init(accounts: AccountStore, agenda: AgendaModel, writer: EventWriter, signIn: @escaping (String?) -> Void,
         showSettings: @escaping () -> Void, refresh: @escaping () -> Void) {
        self.accounts = accounts
        self.agenda = agenda
        self.writer = writer
        newItem = NewItemModel(agenda: agenda, writer: writer, accounts: accounts)
        self.signIn = signIn
        self.showSettings = showSettings
        self.refresh = refresh
    }

    func focusInput() { focusRequest += 1 }

    /// The new-item suggestion list shows, and takes keys, only while typing a new item, not in search.
    var showsSuggestions: Bool { !agenda.searchMode && newItem.showsSuggestions }

    /// Every open starts on today (§4) with the agenda list, not search.
    func willOpen() {
        agenda.isVisible = true
        agenda.searchMode = false
        agenda.query = ""
        agenda.selectedEvent = nil
        agenda.resetToToday()
        // a double-clicked day dates only the entry it started
        if input.isEmpty { newItem.defaultDay = nil }
    }

    /// Esc: hides suggestions; clears the field if it has text; leaves search; otherwise closes the
    /// popover (§4, §9, §11).
    func escape() {
        if showsSuggestions {
            newItem.dismissSuggestions()
        } else if agenda.searchMode {
            if agenda.query.isEmpty { toggleSearch() } else { agenda.query = "" }
        } else if input.isEmpty {
            close()
        } else {
            cancelNewItem()
        }
    }

    /// × or Esc on a new item: asks first when the form was edited by hand (§8.3).
    func cancelNewItem() {
        if newItem.needsDiscardConfirmation && !Dialogs.confirmDiscard() { return }
        input = ""
        newItem.defaultDay = nil
        focusInput()
    }

    /// Enter or Add Event (§5.4): adds, clears, and returns to today after ~2 s.
    func addNewItem() {
        guard newItem.add() else { return }
        input = ""
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            // unless the user started something else in the meantime
            guard let self, input.isEmpty, !agenda.searchMode, agenda.selectedEvent == nil else { return }
            agenda.resetToToday()
        }
    }

    /// Double-clicking a day starts a new entry dated that day (§4.2).
    func startNewItem(on day: Date) {
        newItem.defaultDay = day
        newItem.update(input: input)
        focusInput()
    }

    func toggleSearch() {
        agenda.searchMode.toggle()
        agenda.query = ""
        focusInput()
    }

    /// Opens the detail popover beside `anchor` (the event's row), or beside the Mini Window.
    func openEvent(_ event: EventInstance, anchor: NSView?) {
        guard let anchor = anchor ?? contentView() else { return }
        let editor = EventEditorModel(event: event, agenda: agenda, writer: writer)
        // to the left of the Mini Window (§6)
        if showChild(anchor, AnyView(EventEditor(model: editor)), 300, .minX, editor.shouldClose) {
            agenda.selectedEvent = event.key
        }
    }

    /// A task's detail popover (§10), saved on close like an event's.
    func openTask(_ task: TaskItem, anchor: NSView?) {
        guard let anchor = anchor ?? contentView() else { return }
        let editor = TaskEditorModel(task: task, agenda: agenda, writer: writer)
        if showChild(anchor, AnyView(TaskEditor(model: editor)), 300, .minX, editor.shouldClose) {
            agenda.selectedEvent = task.key
        }
    }

    /// ≡ › Tasks (⌘R) and ≡ › Month (⌘3) (§10).
    func showTasks(_ shown: Bool) {
        agenda.showsTasks = shown
        agenda.selectedEvent = nil
    }

    /// Go to Date… (§4.4): a date picker beside the Mini Window.
    func goToDate() {
        guard let view = contentView() else { return }
        _ = showChild(view, AnyView(GoToDate(initial: agenda.selectedDay) { [weak self] day in
            self?.agenda.select(day)
        }), 240, .minX, nil)
    }

    /// The Notifications popover (§6.2), anchored to the invitation badge.
    func showNotifications(anchor: NSView) {
        // below the badge, over the grid (§6.2); the anchor view is not flipped, so minY is its bottom
        _ = showChild(anchor, AnyView(NotificationsView(model: self)), 300, .minY, nil)
    }

    // MARK: Event actions (§7.1, §8)

    /// The selected event in the agenda list, if it is still cached.
    var selectedEvent: EventInstance? {
        guard let key = agenda.selectedEvent else { return nil }
        return agenda.sections.lazy.flatMap { $0.allDay + $0.timed }.first { $0.key == key }
    }

    /// Go to Previous / Next Occurrence (§7.1): selects that occurrence's day and the occurrence.
    func goToOccurrence(of event: EventInstance, forward: Bool) {
        guard let series = event.recurringEventId,
              let next = try? agenda.cache.occurrence(after: event, in: series, forward: forward) else { return }
        agenda.select(next.start)
        agenda.selectedEvent = next.key
    }

    /// Copy (§7.1): the event as text, for pasting into a message.
    func copy(_ event: EventInstance) {
        var lines = [event.summary]
        lines.append(event.allDay ? event.start.formatted(date: .complete, time: .omitted)
                     : "\(event.start.formatted(date: .complete, time: .omitted)), \(Formatting.timeRange(event.start, event.end))")
        if let location = event.location, !location.isEmpty { lines.append(location) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    /// The selected task, in the agenda or the Tasks view.
    var selectedTask: TaskItem? {
        guard let key = agenda.selectedEvent else { return nil }
        return agenda.sections.lazy.flatMap(\.tasks).first { $0.key == key }
            ?? agenda.taskRows.lazy.map(\.task).first { $0.key == key }
    }

    func deleteTask(_ task: TaskItem) {
        writer.deleteTask(task)
        agenda.selectedEvent = nil
    }

    /// ⌫ and Delete Item: the selected event or task.
    func deleteSelection() {
        if let event = selectedEvent { delete(event) } else if let task = selectedTask { deleteTask(task) }
    }

    var hasSelection: Bool { selectedEvent != nil || selectedTask != nil }

    /// Duplicate as Task (§7.1): due on the event's day, in the event account's first list.
    func duplicateAsTask(_ event: EventInstance) {
        guard let list = agenda.defaultTaskList(account: event.account) else { return }
        writer.insertTask(title: event.summary, notes: event.notes, due: Calendar.current.startOfDay(for: event.start),
                          account: list.account, listId: list.id)
    }

    /// Duplicate as Event (§7.3): an all-day event on the due day (today when undated), on the
    /// primary calendar of the task's account.
    func duplicateAsEvent(_ task: TaskItem) {
        guard let calendar = agenda.defaultCalendar(account: task.account) else { return }
        var draft = EventDraft(parsed: ParsedItem(title: task.title, allDayOn: task.due ?? agenda.today),
                               account: calendar.account, calendarId: calendar.id)
        draft.notes = task.notes ?? ""
        writer.insert(draft)
    }

    func delete(_ event: EventInstance) {
        guard let scope = Dialogs.scope(for: event) else { return }
        writer.delete(event, scope: scope)
        agenda.selectedEvent = nil
    }

    func respond(_ event: EventInstance, _ response: String) {
        guard let scope = Dialogs.scope(for: event) else { return }
        writer.respond(event, response: response, scope: scope)
    }

    /// Color ›, Show As ›, Visibility › from the context menu: one field, saved at once.
    func quickEdit(_ event: EventInstance, _ change: (inout EventDraft) -> Void) {
        let original = EventDraft(event, recurrence: nil)
        var draft = original
        change(&draft)
        guard draft != original, let scope = Dialogs.scope(for: event) else { return }
        // color, busy/free and visibility need none of the series' own data (its times or rule)
        writer.save(event, original: original, draft: draft, scope: scope, series: nil)
    }

    func setSelected(_ selected: Bool, calendar: CalendarInfo) {
        Task {
            do {
                try await agenda.engine.setSelected(selected, calendar: calendar)
            } catch {
                Log.sync.error("calendar visibility write failed: \(error.localizedDescription)")
            }
        }
    }

    /// Returns true when the key was handled (§11).
    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        // the suggestion list takes ↑ ↓ Enter Tab while it shows (§5.2)
        if showsSuggestions, flags.isEmpty {
            switch event.keyCode {
            case 126: newItem.moveSelection(by: -1); return true
            case 125: newItem.moveSelection(by: 1); return true
            case 36, 76, 48: input = newItem.accept(in: input); return true
            default: break
            }
        }
        if !input.isEmpty, !agenda.searchMode, flags.isEmpty, event.keyCode == 36 || event.keyCode == 76 {
            addNewItem()
            return true
        }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch (flags, key) {
        case ([.command], "f"): if !agenda.searchMode { toggleSearch() }; return true
        case ([.command], "t"): agenda.resetToToday(); return true
        case ([.command, .shift], "t"): goToDate(); return true
        case ([.command, .shift], "r"): refresh(); return true
        case ([.command], "z"): writer.undoDelete(); return true
        case ([.command], "r"): showTasks(true); return true
        case ([.command], "3"): showTasks(false); return true
        default: break
        }
        // ⌫ / ⌘⌫ delete the selected event (§4.3)
        if input.isEmpty, !agenda.searchMode, event.keyCode == 51, flags.isEmpty || flags == [.command],
           hasSelection {
            deleteSelection()
            return true
        }
        guard input.isEmpty, !agenda.searchMode else { return false }
        switch (flags.subtracting(.function), event.keyCode) {
        case ([], 123): agenda.moveMonth(by: -1)         // ←
        case ([], 124): agenda.moveMonth(by: 1)          // →
        case ([.shift], 123): agenda.moveDay(by: -1)     // ⇧←
        case ([.shift], 124): agenda.moveDay(by: 1)      // ⇧→
        case ([.shift], 126): agenda.moveDay(by: -7)     // ⇧↑
        case ([.shift], 125): agenda.moveDay(by: 7)      // ⇧↓
        default: return false
        }
        return true
    }
}

private struct GoToDate: View {
    @State var day: Date
    let go: (Date) -> Void

    init(initial: Date, go: @escaping (Date) -> Void) {
        _day = State(initialValue: initial)
        self.go = go
    }

    var body: some View {
        VStack(spacing: 8) {
            DatePicker("", selection: $day, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
            Button("Go") { go(day) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
        .background(Theme.background)
        .tint(Theme.accent)
    }
}

private final class PopoverBackgroundView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used from a nib") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // resolved here, inside the view's appearance, so light and dark both update
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.nsBackground.cgColor
        }
    }
}
