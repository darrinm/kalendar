// The Mini Window: a transient NSPopover anchored to the status item (§4), plus the detail popover
// that opens beside it (§6).
//
// The detail popover is shown relative to a view *inside* the main popover, which makes it a child
// popover: AppKit keeps the parent open while the user clicks in the child, and closes the child
// when the parent closes. That is the arrangement milestone 1 exists to prove (spec §13).
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

    init(accounts: AccountStore, signIn: @escaping (String?) -> Void, showSettings: @escaping () -> Void) {
        model = PopoverModel(accounts: accounts, signIn: signIn, showSettings: showSettings)
        super.init()
        popover.behavior = .transient
        popover.contentSize = Self.size
        popover.delegate = self
        model.close = { [weak self] in self?.close() }
        model.showDetail = { [weak self] view, content in self?.showDetail(relativeTo: view, content: content) }
        popover.contentViewController = NSHostingController(rootView: PopoverRoot(model: model))
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            close()
            return
        }
        // An accessory app is not active until told to be; without this the text field cannot
        // become first responder when the popover opens from the global hotkey.
        NSApp.activate(ignoringOtherApps: true)
        anchor = button
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        model.focusInput()
    }

    func close() {
        detail?.close()
        popover.performClose(nil)
    }

    private func showDetail(relativeTo view: NSView, content: AnyView) {
        detail?.close()
        let child = NSPopover()
        child.behavior = .transient
        child.contentViewController = NSHostingController(rootView: content.frame(width: 300))
        // to the left of the Mini Window (§6); AppKit flips it to the right when there is no room
        child.show(relativeTo: view.bounds, of: view, preferredEdge: .minX)
        detail = child
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
        }
    }
}

/// State and callbacks the SwiftUI content needs from the AppKit shell.
@MainActor
@Observable
final class PopoverModel {
    let accounts: AccountStore
    let signIn: (String?) -> Void
    let showSettings: () -> Void
    var input = ""
    /// Bumped to ask the input field to take focus.
    var focusRequest = 0
    @ObservationIgnored var close: () -> Void = {}
    @ObservationIgnored var showDetail: (NSView, AnyView) -> Void = { _, _ in }

    init(accounts: AccountStore, signIn: @escaping (String?) -> Void, showSettings: @escaping () -> Void) {
        self.accounts = accounts
        self.signIn = signIn
        self.showSettings = showSettings
    }

    func focusInput() { focusRequest += 1 }

    /// Esc: clears the input if it has text, otherwise closes the popover (§4).
    func escape() {
        if input.isEmpty { close() } else { input = "" }
    }
}
