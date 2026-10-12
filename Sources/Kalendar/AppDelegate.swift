import AppKit
import KalendarCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let accounts = AccountStore()
    private var statusItem: StatusItemController!
    private var popover: PopoverController!
    private lazy var settings = SettingsWindowController(accounts: accounts, signIn: signIn)
    private lazy var googleSignIn = GoogleSignIn(accounts: accounts)

    func applicationDidFinishLaunching(_ notification: Notification) {
        popover = PopoverController(accounts: accounts, signIn: signIn,
                                    showSettings: { [weak self] in self?.showSettings() })
        statusItem = StatusItemController(
            onToggle: { [weak self] in self?.togglePopover() },
            menu: makeStatusMenu())
        HotkeyCenter.shared.handler = { [weak self] in self?.togglePopover() }
        HotkeyCenter.shared.install()
        _ = UpdaterController.shared   // starts Sparkle's scheduled checks; `shared` is lazy
        LaunchAtLogin.enableOnFirstLaunch()
        // `open Kalendar.app --args -openPopoverAtLaunch YES` opens the popover for UI testing.
        // Delayed because the status item has no on-screen position yet at launch, and NSPopover
        // silently refuses to show against it.
        if UserDefaults.standard.bool(forKey: "openPopoverAtLaunch") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.togglePopover() }
        }
    }

    func togglePopover() {
        guard let button = statusItem.button else { return }
        popover.toggle(relativeTo: button)
    }

    /// Starts Google sign-in. `email` re-authorizes that account; nil adds a new one.
    func signIn(_ email: String?) {
        popover.close()
        Task { await googleSignIn.run(loginHint: email) }
    }

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        menu.addItem(withTitle: "About Kalendar", action: #selector(showAbout), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Kalendar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc func showSettings() {
        popover.close()
        settings.show()
    }

    @objc private func checkForUpdates() { UpdaterController.shared.checkForUpdates() }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(checkForUpdates) { return UpdaterController.shared.canCheckNow }
        return true
    }
}
