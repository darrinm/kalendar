import AppKit
import KalendarCore
import Network

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let accounts = AccountStore()
    private var cache: CalendarCache!
    private var engine: SyncEngine!
    private var writer: EventWriter!
    private var statusItem: StatusItemController!
    private var popover: PopoverController!
    private lazy var settings = SettingsWindowController(accounts: accounts, cache: cache, engine: engine, signIn: signIn)
    private lazy var googleSignIn = GoogleSignIn(accounts: accounts)
    private var syncTimer: Timer?
    private let network = NWPathMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        cache = Self.openCache()
        engine = SyncEngine(accounts: accounts, cache: cache)
        writer = EventWriter(accounts: accounts, cache: cache, engine: engine)
        // queued writes go out before each sync, so a sync never overwrites an unsent edit
        engine.beforeSync = { [weak self] in await self?.writer.flush() }
        accounts.onSignedOut = { [weak self] email in self?.engine.removeAccount(email) }
        let agenda = AgendaModel(cache: cache, engine: engine)
        let model = PopoverModel(accounts: accounts, agenda: agenda, writer: writer, signIn: signIn,
                                 showSettings: { [weak self] in self?.showSettings() },
                                 refresh: { [weak self] in self?.sync() })
        popover = PopoverController(model: model)
        popover.onOpen = { [weak self] in self?.syncIfNeeded(maxAge: 30) }
        statusItem = StatusItemController(
            onToggle: { [weak self] in self?.togglePopover() },
            menu: makeStatusMenu())
        HotkeyCenter.shared.handler = { [weak self] in self?.togglePopover() }
        HotkeyCenter.shared.install()
        _ = UpdaterController.shared   // starts Sparkle's scheduled checks; `shared` is lazy
        LaunchAtLogin.enableOnFirstLaunch()
        startSyncTriggers()
        // `open Kalendar.app --args -openPopoverAtLaunch YES` opens the popover for UI testing.
        // Delayed because the status item has no on-screen position yet at launch, and NSPopover
        // silently refuses to show against it.
        if UserDefaults.standard.bool(forKey: "openPopoverAtLaunch") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.togglePopover() }
        }
    }

    /// The on-disk cache, or an in-memory one if the file can't be opened: Kalendar still works, it
    /// just starts empty each launch.
    private static func openCache() -> CalendarCache {
        do {
            return try CalendarCache(path: CalendarCache.defaultPath)
        } catch {
            Log.sync.error("cache open failed, using memory: \(error.localizedDescription)")
            return try! CalendarCache()
        }
    }

    // MARK: Sync triggers (§18.3)

    private func startSyncTriggers() {
        sync()
        // every 60 s while the popover is open, every 5 min otherwise
        syncTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.syncIfNeeded(maxAge: self.popover.isShown ? 55 : 295)
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        var wasOffline = false
        network.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                let online = path.status == .satisfied
                if online, wasOffline { self?.sync() }
                wasOffline = !online
            }
        }
        network.start(queue: .global(qos: .utility))
    }

    func sync() { Task { await engine.syncAll() } }

    private func syncIfNeeded(maxAge: TimeInterval) { Task { await engine.syncIfNeeded(maxAge: maxAge) } }

    // MARK: Actions

    func togglePopover() {
        guard let button = statusItem.button else { return }
        popover.toggle(relativeTo: button)
    }

    /// Starts Google sign-in. `email` re-authorizes that account; nil adds a new one.
    func signIn(_ email: String?) {
        popover.close()
        Task {
            await googleSignIn.run(loginHint: email)
            sync()
        }
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
