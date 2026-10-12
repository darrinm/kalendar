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
        model.showChild = { [weak self] view, content, width in self?.showChild(relativeTo: view, content: content, width: width) }
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
        detail?.close()
        popover.performClose(nil)
    }

    private func showChild(relativeTo view: NSView, content: AnyView, width: CGFloat) {
        detail?.close()
        let child = NSPopover()
        child.behavior = .transient
        child.contentViewController = NSHostingController(rootView: content.frame(width: width))
        // to the left of the Mini Window (§6); AppKit flips it to the right when there is no room
        child.show(relativeTo: view.bounds, of: view, preferredEdge: .minX)
        Self.paintFrame(of: child)
        detail = child
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
        guard popover === self.popover, let window = anchor?.window,
              let event = NSApp.currentEvent, event.type == .leftMouseDown else { return true }
        return event.window !== window
    }

    func popoverDidClose(_ notification: Notification) {
        if (notification.object as? NSPopover) === popover {
            detail?.close()
            detail = nil
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
    var input = ""
    /// Bumped to ask the input field to take focus.
    var focusRequest = 0
    @ObservationIgnored var close: () -> Void = {}
    @ObservationIgnored var showChild: (NSView, AnyView, CGFloat) -> Void = { _, _, _ in }
    @ObservationIgnored var contentView: () -> NSView? = { nil }

    init(accounts: AccountStore, agenda: AgendaModel, signIn: @escaping (String?) -> Void,
         showSettings: @escaping () -> Void, refresh: @escaping () -> Void) {
        self.accounts = accounts
        self.agenda = agenda
        self.signIn = signIn
        self.showSettings = showSettings
        self.refresh = refresh
    }

    func focusInput() { focusRequest += 1 }

    /// Every open starts on today (§4) with the agenda list, not search.
    func willOpen() {
        agenda.isVisible = true
        agenda.searchMode = false
        agenda.query = ""
        agenda.selectedEvent = nil
        agenda.resetToToday()
    }

    /// Esc: clears the field if it has text; leaves search; otherwise closes the popover (§4, §9).
    func escape() {
        if agenda.searchMode {
            if agenda.query.isEmpty { toggleSearch() } else { agenda.query = "" }
        } else if input.isEmpty {
            close()
        } else {
            input = ""
        }
    }

    func toggleSearch() {
        agenda.searchMode.toggle()
        agenda.query = ""
        focusInput()
    }

    func openEvent(_ event: EventInstance, anchor: NSView) {
        showChild(anchor, AnyView(EventDetail(event: event, model: agenda)), 300)
    }

    /// Go to Date… (§4.4): a date picker beside the Mini Window.
    func goToDate() {
        guard let view = contentView() else { return }
        showChild(view, AnyView(GoToDate(initial: agenda.selectedDay) { [weak self] day in
            self?.agenda.select(day)
        }), 240)
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
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch (flags, key) {
        case ([.command], "f"): if !agenda.searchMode { toggleSearch() }; return true
        case ([.command], "t"): agenda.resetToToday(); return true
        case ([.command, .shift], "t"): goToDate(); return true
        case ([.command, .shift], "r"): refresh(); return true
        default: break
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
