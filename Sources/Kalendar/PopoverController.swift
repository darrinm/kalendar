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
    /// When the popover last closed. A transient popover closes on mouse-down outside itself, which
    /// includes the status item; the status item's action then fires on mouse-up and would reopen it.
    private var closedAt = Date.distantPast
    private let model: PopoverModel

    init(accounts: AccountStore, signIn: @escaping (String?) -> Void, showSettings: @escaping () -> Void) {
        model = PopoverModel(accounts: accounts, signIn: signIn, showSettings: showSettings)
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = Self.size
        popover.delegate = self
        model.close = { [weak self] in self?.close() }
        model.showDetail = { [weak self] view, content in self?.showDetail(relativeTo: view, content: content) }
        popover.contentViewController = NSHostingController(rootView: PopoverRoot(model: model))
    }

    var isShown: Bool { popover.isShown }

    func toggle(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            close()
            return
        }
        if NSApp.currentEvent?.type == .leftMouseUp, Date().timeIntervalSince(closedAt) < 0.5 { return }
        // An accessory app is not active until told to be; without this the text field cannot
        // become first responder when the popover opens from the global hotkey.
        NSApp.activate(ignoringOtherApps: true)
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
        child.animates = true
        child.contentViewController = NSHostingController(rootView: content.frame(width: 300))
        // to the left of the Mini Window (§6); AppKit flips it to the right when there is no room
        child.show(relativeTo: view.bounds, of: view, preferredEdge: .minX)
        detail = child
    }

    func popoverDidClose(_ notification: Notification) {
        if (notification.object as? NSPopover) === popover {
            closedAt = Date()
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
