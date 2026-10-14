// The Mini Window: a panel hung just below the menu bar under the status item (§4), as the
// system's menu bar extras are (Sound, Wi-Fi), with no arrow. Beside it open the popovers for the
// event detail (§6) and Go to Date.
//
// Those are shown relative to a view inside the panel. AppKit closes a transient popover on a click
// outside it, and the panel closes them when it closes (spec §13).
import AppKit
import KalendarCore
import SwiftUI

@MainActor
final class PopoverController: NSObject, NSPopoverDelegate {
    /// The Mini Window grows with the text size (§12). 850 pt gives the agenda list about twice the
    /// room it had at 600 (the grid above it is fixed); a screen too short for that gets its full height.
    static func size(scale: CGFloat) -> NSSize {
        let room = (NSScreen.main?.visibleFrame.height ?? 900) - 20
        return NSSize(width: (320 * scale).rounded(), height: min((850 * scale).rounded(), room))
    }
    private static var size: NSSize { size(scale: Preferences.shared.textSize.scale) }
    /// The gap between the menu bar and the panel's top edge, as the system's menu bar extras leave.
    private static let menuBarGap: CGFloat = 6

    private let panel = MiniPanel()
    private var detail: NSPopover?
    /// The status item button the panel opens under.
    private weak var anchor: NSStatusBarButton?
    private let model: PopoverModel
    private var keyMonitor: Any?
    /// Clicks in other apps and in this app's other windows, which close the panel.
    private var clickMonitors: [Any] = []
    private var resignObserver: NSObjectProtocol?
    /// Called each time the panel opens; the app syncs then (§18.3).
    var onOpen: () -> Void = {}

    init(model: PopoverModel) {
        self.model = model
        super.init()
        model.close = { [weak self] in self?.close() }
        model.showChild = { [weak self] view, content, width, edge, shouldClose in
            self?.showChild(relativeTo: view, content: content, width: width, edge: edge, shouldClose: shouldClose) ?? false
        }
        model.contentView = { [weak self] in self?.panel.contentViewController?.view }
        model.childShown = { [weak self] in self?.detail != nil }
        model.closeChild = { [weak self] in self?.closeChild() ?? true }
        panel.contentViewController = NSHostingController(rootView: TextScaled(PopoverRoot(model: model)))
        panel.round()
    }

    var isShown: Bool { panel.isVisible }

    func toggle(relativeTo button: NSStatusBarButton) {
        if panel.isVisible {
            close()
            return
        }
        // Pressing the status item makes the app resign active, which already closed the panel; the
        // item's action on mouse-up is that same click, so it must not open the panel again.
        if NSApp.currentEvent?.type == .leftMouseUp, let closedAt, Date().timeIntervalSince(closedAt) < 0.5 {
            return
        }
        // An accessory app is not active until told to be; without this the text field cannot
        // become first responder when the panel opens from the global hotkey.
        NSApp.activate(ignoringOtherApps: true)
        anchor = button
        model.willOpen()
        panel.setFrame(frame(under: button), display: true)
        panel.round()
        panel.makeKeyAndOrderFront(nil)
        Self.setHighlight(true, on: button)
        model.focusInput()
        installMonitors()
        onOpen()
    }

    /// Centered under the status item, its top just below the menu bar, kept on the item's screen.
    private func frame(under button: NSStatusBarButton) -> NSRect {
        let size = Self.size
        guard let window = button.window, let screen = window.screen ?? NSScreen.main else {
            return NSRect(origin: .zero, size: size)
        }
        let item = window.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = screen.visibleFrame
        let x = min(max(item.midX - size.width / 2, visible.minX + 8), visible.maxX - 8 - size.width)
        let top = min(item.minY, visible.maxY) - Self.menuBarGap
        return NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
    }

    /// Esc, the status item, a click elsewhere, or switching apps. Stays open while a dialog (§8)
    /// is up, or when the detail popover's save was cancelled (§8.1).
    func close() {
        guard panel.isVisible, NSApp.modalWindow == nil, closeChild() else { return }
        panel.orderOut(nil)
        didClose()
    }

    /// When the panel last closed, for `toggle`.
    private var closedAt: Date?

    private func didClose() {
        closedAt = Date()
        if let anchor { Self.setHighlight(false, on: anchor) }
        model.agenda.isVisible = false
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        clickMonitors.forEach(NSEvent.removeMonitor)
        clickMonitors = []
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }

    /// The menu bar item stays highlighted while the panel is open, as a menu's does. The menu bar
    /// draws that highlight only for an item's own menu or popover, so it is drawn here: a rounded
    /// tint in the menu bar's text color behind the icon.
    private static func setHighlight(_ on: Bool, on button: NSStatusBarButton) {
        button.wantsLayer = true
        guard let layer = button.layer else { return }
        layer.cornerRadius = 6
        layer.cornerCurve = .continuous
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = on ? NSColor.labelColor.withAlphaComponent(0.2).cgColor : nil
        }
    }

    /// The open child popover's save-on-close, if it is an event's or a task's detail popover.
    private var shouldClose: (() -> Bool)?

    /// Closes the open child popover, saving an event's edits first. False when the user cancelled
    /// the recurring-event question (§8.1), so everything stays open.
    private func closeChild() -> Bool {
        guard saveChild() else { return false }
        dismissChild()
        return true
    }

    /// Saves the open child's edits. False when the user cancelled the recurring-event question.
    private func saveChild() -> Bool {
        shouldClose?() ?? true
    }

    /// Closes the child popover without asking; any unsaved edits are dropped.
    private func dismissChild() {
        shouldClose = nil
        detail?.close()
        detail = nil
    }

    /// Opens a child popover beside `view`. With one already open, its edits are saved and the same
    /// popover takes the new content and moves to the new anchor, so going from item to item
    /// updates it in place instead of closing and reopening it.
    @discardableResult
    private func showChild(relativeTo view: NSView, content: AnyView, width: CGFloat, edge: NSRectEdge,
                           shouldClose: (() -> Bool)?) -> Bool {
        pendingChildDismiss = false
        if let detail, detail.isShown {
            guard saveChild() else { return false }
            // The tap that called this can be running in the previous content's view (a row of the
            // Notifications popover). That view is released on the next turn of the run loop.
            let previous = detail.contentViewController
            detail.contentViewController = Self.hosting(content, width: width)
            DispatchQueue.main.async { withExtendedLifetime(previous) {} }
            detail.show(relativeTo: view.bounds, of: view, preferredEdge: edge)
            self.shouldClose = shouldClose
            return true
        }
        guard closeChild() else { return false }
        let child = NSPopover()
        child.behavior = .transient
        child.delegate = self
        child.contentViewController = Self.hosting(content, width: width)
        // AppKit flips to the opposite edge when there is no room
        child.show(relativeTo: view.bounds, of: view, preferredEdge: edge)
        Self.paintFrame(of: child)
        detail = child
        self.shouldClose = shouldClose
        return true
    }

    private static func hosting(_ content: AnyView, width: CGFloat) -> NSViewController {
        NSHostingController(rootView: TextScaled(content.frame(width: width)))
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

    /// The detail popover saves on close (§6) and may ask about a recurring event first. A dialog
    /// (§8) taking key must not close it either: Cancel returns to it.
    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        if NSApp.modalWindow != nil { return false }
        guard popover === detail else { return true }
        // A click in the panel may be on another row, whose tap moves this popover to that item.
        // Let the click finish; close only if it opened nothing.
        if let event = NSApp.currentEvent, event.type == .leftMouseDown || event.type == .leftMouseUp,
           event.window === panel {
            deferChildDismiss(afterMouseUp: event.type == .leftMouseDown)
            return false
        }
        guard shouldClose?() ?? true else { return false }
        shouldClose = nil
        return true
    }

    /// Set by a click in the panel while a child popover is open; cleared when that click opens
    /// another item in it.
    private var pendingChildDismiss = false

    /// AppKit asks on mouse-down or on mouse-up. A row's tap gesture runs on the mouse-up, after
    /// this, so the check waits for that mouse-up and then one turn of the run loop.
    private func deferChildDismiss(afterMouseUp: Bool) {
        pendingChildDismiss = true
        guard afterMouseUp else { return checkChildDismiss() }
        var monitor: Any?
        let mouseUp = { [weak self] in
            guard let installed = monitor else { return }
            NSEvent.removeMonitor(installed)
            monitor = nil
            self?.checkChildDismiss()
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { event in
            mouseUp()
            return event
        }
        // A button, a text field, or a menu tracks the mouse itself and takes the mouse-up, so the
        // monitor never receives it. This block runs in the default mode, after any such tracking
        // ends. With the button up and no mouse-up waiting in the queue, the mouse-up was taken.
        RunLoop.main.perform(inModes: [.default]) {
            MainActor.assumeIsolated {
                guard NSEvent.pressedMouseButtons & 1 == 0,
                      NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default,
                                      dequeue: false) == nil else { return }
                mouseUp()
            }
        }
    }

    /// Closes the child popover one turn of the run loop from now, unless a click opened another item.
    private func checkChildDismiss() {
        DispatchQueue.main.async { [weak self] in
            guard let self, pendingChildDismiss else { return }
            pendingChildDismiss = false
            _ = closeChild()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        if (notification.object as? NSPopover) === detail {
            detail = nil
            model.agenda.selection = nil
        }
    }

    /// Keyboard shortcuts (§11) that the text field would otherwise consume, and the clicks and app
    /// switches that close the panel as they would a menu.
    private func installMonitors() {
        if keyMonitor == nil {
            // Arrow keys navigate only while the input is empty, so they still move the caret in typed text
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === panel else { return event }
                return model.handleKey(event) ? nil : event
            }
        }
        guard clickMonitors.isEmpty else { return }
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) {
            clickMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: clicks, handler: { [weak self] event in
            guard let self else { return event }
            // the panel, its detail popover, a menu or dialog it opened, and the status item (whose
            // action closes the panel on mouse-up) keep it open; another window of the app closes it
            let window = event.window
            if window !== panel, window !== detail?.contentViewController?.view.window,
               window !== anchor?.window, window?.level ?? .normal < .popUpMenu, NSApp.modalWindow == nil {
                close()
            }
            return event
        }) {
            clickMonitors.append(local)
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }
}

/// The Mini Window's window: borderless, rounded, shadowed, and able to take keyboard focus for
/// the input field.
private final class MiniPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    override var canBecomeKey: Bool { true }

    /// Rounded like the system's menu bar extras, with a hairline edge that reads on any wallpaper.
    func round() {
        guard let view = contentView else { return }
        view.wantsLayer = true
        view.layer?.cornerRadius = 12
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        view.layer?.borderWidth = 0.5
        // resolved in the current theme; `toggle` calls this on every open
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
}

extension SyncEngine {
    /// The calendar visibility toggles (§4.4, §12): a failed write is logged; the engine reverts it.
    func setVisible(_ selected: Bool, calendar: CalendarInfo) async {
        do {
            try await setSelected(selected, calendar: calendar)
        } catch {
            Log.sync.error("calendar visibility write failed: \(error.localizedDescription)")
        }
    }
}

/// Applies the Text size setting (§12) to a hosted view tree, following changes.
struct TextScaled<Content: View>: View {
    let content: Content
    init(_ content: Content) { self.content = content }

    var body: some View {
        content.environment(\.textScale, Preferences.shared.textSize.scale)
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
    /// Opens the Meet With window (§21).
    @ObservationIgnored var showMeetWith: () -> Void = {}
    /// Shows a popover beside the Mini Window; false when the open one refused to close.
    @ObservationIgnored var showChild: (NSView, AnyView, CGFloat, NSRectEdge, (() -> Bool)?) -> Bool = { _, _, _, _, _ in false }
    @ObservationIgnored var contentView: () -> NSView? = { nil }
    @ObservationIgnored var childShown: () -> Bool = { false }
    /// Closes the detail popover, saving it; false when the user cancelled.
    @ObservationIgnored var closeChild: () -> Bool = { true }

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
            guard let self, Preferences.shared.goToTodayAfterAdding, input.isEmpty, !agenda.searchMode,
                  agenda.selection == nil else { return }
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
            agenda.selection = event.key
        }
    }

    /// A task's detail popover (§10), saved on close like an event's.
    func openTask(_ task: TaskItem, anchor: NSView?) {
        guard let anchor = anchor ?? contentView() else { return }
        let editor = TaskEditorModel(task: task, agenda: agenda, writer: writer)
        if showChild(anchor, AnyView(TaskEditor(model: editor)), 300, .minX, editor.shouldClose) {
            agenda.selection = task.key
        }
    }

    /// ≡ › Tasks (⌘R) and ≡ › Month (⌘3) (§10).
    func showTasks(_ shown: Bool) {
        agenda.showsTasks = shown
        agenda.selection = nil
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

    /// A row of the list the keyboard moves through.
    enum ListItem {
        case event(EventInstance), task(TaskItem)
        var key: String {
            switch self {
            case .event(let e): e.key
            case .task(let t): t.key
            }
        }
    }

    /// The rows on screen, in order: search results, the Tasks view, or the agenda. An event that
    /// spans several days is listed under each, so ↑ ↓ use `listItems`, which keeps its first.
    private var rows: some Sequence<ListItem> {
        if agenda.searchMode {
            return AnySequence(agenda.searchResults.lazy.flatMap { ($0.allDay + $0.timed).map(ListItem.event) })
        }
        if agenda.showsTasks { return AnySequence(agenda.taskRows.lazy.map { .task($0.task) }) }
        return AnySequence(agenda.sections.lazy.flatMap { s in
            s.allDay.map(ListItem.event) + s.tasks.map(ListItem.task) + s.timed.map(ListItem.event)
        })
    }

    /// Each row once, so ↓ can move past a multi-day event.
    var listItems: [ListItem] {
        var seen = Set<String>()
        return rows.filter { seen.insert($0.key).inserted }
    }

    /// The selected row, if it is still listed; stops at the first match.
    private var selectedItem: ListItem? {
        guard let key = agenda.selection else { return nil }
        return rows.first { $0.key == key }
    }

    func moveSelection(by delta: Int) {
        let items = listItems
        guard !items.isEmpty else { return }
        // with nothing selected, ↓ starts at the first row and ↑ at the last
        let index = items.firstIndex { $0.key == agenda.selection }.map { $0 + delta } ?? (delta > 0 ? 0 : items.count - 1)
        agenda.selection = items[min(max(index, 0), items.count - 1)].key
    }

    /// Enter, ⌘E: the selection's detail popover beside the Mini Window.
    func openSelection() {
        switch selectedItem {
        case .event(let e): openEvent(e, anchor: nil)
        case .task(let t): openTask(t, anchor: nil)
        case nil: break
        }
    }

    /// ⌘E / ⌘I (§11): shows or hides the selection's detail popover.
    func toggleDetail() {
        if childShown() { _ = closeChild() } else { openSelection() }
    }

    /// ⌘N (§11): the input, ready for a new event.
    func startNewEntry() {
        if agenda.searchMode { toggleSearch() }
        agenda.showsTasks = false
        agenda.selection = nil
        focusInput()
    }

    /// Go to Previous / Next Occurrence (§7.1): selects that occurrence's day and the occurrence.
    func goToOccurrence(of event: EventInstance, forward: Bool) {
        guard let series = event.recurringEventId,
              let next = try? agenda.cache.occurrence(after: event, in: series, forward: forward) else { return }
        agenda.select(next.start)
        agenda.selection = next.key
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

    func deleteTask(_ task: TaskItem) {
        writer.deleteTask(task)
        agenda.selection = nil
    }

    /// ⌫ and Delete Item: the selected event or task.
    func deleteSelection() {
        switch selectedItem {
        case .event(let e): delete(e)
        case .task(let t): deleteTask(t)
        case nil: break
        }
    }

    var hasSelection: Bool { selectedItem != nil }

    /// Duplicate as Task (§7.1): due on the event's day, in the event account's first list.
    func duplicateAsTask(_ event: EventInstance) {
        guard let list = agenda.defaultTaskList(account: event.account) else { return }
        writer.insertTask(title: event.summary, notes: event.notes, due: Calendar.current.startOfDay(for: event.start),
                          account: list.account, listId: list.id)
    }

    /// Duplicate as Event (§7.3): an all-day event on the due day (today when undated), on the
    /// Default calendar, else the primary calendar of the task's account.
    func duplicateAsEvent(_ task: TaskItem) {
        guard let calendar = agenda.defaultCalendar(account: task.account) else { return }
        var draft = EventDraft(parsed: ParsedItem(title: task.title, allDayOn: task.due ?? agenda.today),
                               account: calendar.account, calendarId: calendar.id)
        draft.notes = task.notes ?? ""
        writer.insert(draft)
    }

    func delete(_ event: EventInstance) {
        // ⌫ on a read-only calendar's event: Google would refuse it
        guard agenda.isWritable(event), let scope = Dialogs.scope(for: event) else { return }
        writer.delete(event, scope: scope)
        agenda.selection = nil
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
        guard draft != original, agenda.isWritable(event), let scope = Dialogs.scope(for: event) else { return }
        // color, busy/free and visibility need none of the series' own data (its times or rule)
        writer.save(event, original: original, draft: draft, scope: scope, series: nil)
    }

    func setSelected(_ selected: Bool, calendar: CalendarInfo) {
        Task { await agenda.engine.setVisible(selected, calendar: calendar) }
    }

    /// Returns true when the key was handled (§11).
    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        // Esc (or ⌘.) from any field, not only the input: a form field would otherwise close the
        // popover. An input method composing text takes Esc to cancel the composition.
        let cancel = (event.keyCode == 53 && flags.isEmpty)
            || (flags == [.command] && event.charactersIgnoringModifiers == ".")
        if cancel {
            if let editor = event.window?.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
            escape()
            return true
        }
        // the suggestion list takes ↑ ↓ Enter Tab while it shows (§5.2)
        if showsSuggestions, flags.isEmpty {
            switch event.keyCode {
            case 126: newItem.moveSelection(by: -1); return true
            case 125: newItem.moveSelection(by: 1); return true
            case 36, 76, 48: input = newItem.accept(in: input); return true
            default: break
            }
        }
        let enter = event.keyCode == 36 || event.keyCode == 76
        if !input.isEmpty, !agenda.searchMode, flags.isEmpty, enter {
            addNewItem()
            return true
        }
        // the list's selection (§11): ↑ ↓ move it, Enter opens it; in search once ⌘↓ chose a result
        let listHasKeys = (input.isEmpty && !agenda.searchMode) || (agenda.searchMode && agenda.selection != nil)
        if listHasKeys, flags.isEmpty {
            if event.keyCode == 126 { moveSelection(by: -1); return true }
            if event.keyCode == 125 { moveSelection(by: 1); return true }
            if enter, hasSelection { openSelection(); return true }
        }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch (flags, key) {
        case ([.command], "n"): startNewEntry(); return true
        case ([.command], "e"), ([.command], "i"): toggleDetail(); return true
        case ([.command], "f"): if !agenda.searchMode { toggleSearch() }; return true
        case ([.command], "t"): agenda.resetToToday(); return true
        case ([.command, .shift], "t"): goToDate(); return true
        case ([.command, .shift], "r"): refresh(); return true
        case ([.command], "z"): writer.undoDelete(); return true
        case ([.command], "r"): showTasks(true); return true
        case ([.command], "3"): showTasks(false); return true
        default: break
        }
        // ⌘↓: from the search field to the first result (§11)
        if agenda.searchMode, flags == [.command], event.keyCode == 125 {
            agenda.selection = listItems.first?.key
            return true
        }
        // ⌫ / ⌘⌫ delete the selected event (§4.3)
        if input.isEmpty, !agenda.searchMode, event.keyCode == 51, flags.isEmpty || flags == [.command],
           hasSelection {
            deleteSelection()
            return true
        }
        guard input.isEmpty, !agenda.searchMode else { return false }
        switch (flags, event.keyCode) {
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
            DatePicker("Go to date", selection: $day, displayedComponents: .date)
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
