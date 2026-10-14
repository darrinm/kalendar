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
    private var alerts: AlertScheduler!
    private lazy var settings = SettingsWindowController(accounts: accounts, cache: cache, engine: engine, alerts: alerts,
                                                         signIn: signIn)
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
        alerts = AlertScheduler(cache: cache)
        engine.onChange = { [weak self] in
            agenda.cacheChanged()
            self?.alerts.setNeedsReschedule()
            self?.statusItem?.redraw()
        }
        let model = PopoverModel(accounts: accounts, agenda: agenda, writer: writer, signIn: signIn,
                                 showSettings: { [weak self] in self?.showSettings() },
                                 refresh: { [weak self] in
                                     self?.engine.forgetContactSync()   // Refresh All refetches contacts too (§18.4)
                                     self?.sync()
                                 })
        popover = PopoverController(model: model)
        alerts.openEvent = { [weak self] event in
            guard let self else { return }
            if !popover.isShown { togglePopover() }
            agenda.select(event.start)
            model.openEvent(event, anchor: nil)
        }
        // with an account, the reschedule follows the permission answer
        if accounts.accounts.isEmpty { alerts.setNeedsReschedule() } else { alerts.requestPermission() }
        popover.onOpen = { [weak self] in self?.syncIfNeeded(maxAge: 30) }
        statusItem = StatusItemController(
            onToggle: { [weak self] in self?.togglePopover() },
            menu: makeStatusMenu())
        HotkeyCenter.shared.handler = { [weak self] in self?.togglePopover() }
        let prefs = Preferences.shared
        HotkeyCenter.shared.register(prefs.hotkey)
        prefs.applyAppearance()
        statusItem.nextEvent = { [weak self] in self?.nextEventToday() }
        statusItem.joinEvent = { [weak self] in self?.joinEvent() }
        // "darrin.massena@example.com" → "darrin"
        statusItem.selfNames = { [weak self] in
            Set(self?.accounts.accounts.compactMap { $0.email.split(whereSeparator: { "@._+".contains($0) }).first?.lowercased() } ?? [])
        }
        statusItem.redraw()
        prefs.onChange = { [weak self] key in
            guard let self else { return }
            switch key {
            case "hotkey": HotkeyCenter.shared.register(prefs.hotkey)
            case "iconStyle", "colorIcon": statusItem.redraw()
            case "showAlerts": alerts.setNeedsReschedule()
            case "listDays": agenda.settingsChanged(restartList: true)
            case "firstWeekday", "showDeclined", "combineIdentical", "showTasksInList", "showCompletedTasks",
                 "taskSort", "hiddenTaskLists":
                agenda.settingsChanged(restartList: false)
            default: break   // the rest are read when used, or observed by the views
            }
        }
        for name in [NSLocale.currentLocaleDidChangeNotification, .NSSystemTimeZoneDidChange] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { prefs.systemCalendarChanged() }
            }
        }
        // `--args -selfTest <file>` runs the Google write paths and quits (SelfTest.swift).
        // Before the sync triggers, so no background sync overlaps the writes it checks.
        if let report = Self.launchArgument("selfTest") {
            Task { [self] in
                var test = SelfTest(accounts: accounts, cache: cache, engine: engine, writer: writer)
                await test.run(reportTo: report)
                NSApp.terminate(nil)
            }
            return
        }
        _ = UpdaterController.shared   // starts Sparkle's scheduled checks; `shared` is lazy
        LaunchAtLogin.enableOnFirstLaunch()
        startSyncTriggers()
        // `--args -renderSnapshots <dir>` renders the UI off screen and quits (Snapshots.swift)
        if let directory = Self.launchArgument("renderSnapshots") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                Snapshots.render(model: model, settings: { [self] tab in
                    SettingsPane(tab: tab, accounts: self.accounts, cache: self.cache, engine: self.engine,
                                 alerts: self.alerts, signIn: self.signIn)
                }, to: directory)
                NSApp.terminate(nil)
            }
        }
        // `open Kalendar.app --args -openPopoverAtLaunch YES` opens the popover for UI testing.
        // Delayed because the status item has no on-screen position yet at launch, and NSPopover
        // silently refuses to show against it.
        if UserDefaults.standard.bool(forKey: "openPopoverAtLaunch") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.togglePopover() }
        }
    }

    /// A `-key value` launch argument. Only the arguments, not the saved defaults: a `selfTest` or
    /// `renderSnapshots` key left in the defaults must not run Google writes or quit on a normal launch.
    private static func launchArgument(_ key: String) -> String? {
        UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[key] as? String
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

    /// The menu bar's next event (§12): the first timed event today, not declined, that hasn't ended.
    private func nextEventToday() -> EventInstance? {
        let now = Date()
        guard let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now)),
              let events = try? cache.events(from: now, to: end) else { return nil }
        return events.first { !$0.allDay && !$0.isDeclined && $0.end > now }
    }

    /// The menu bar's Join item (§3): the meeting in progress or starting within 15 minutes.
    private func joinEvent() -> EventInstance? {
        let now = Date()
        // the query's end is exclusive; a minute past the lead includes a meeting starting exactly at it
        let to = now.addingTimeInterval(ConferenceDetector.joinLead + 60)
        guard let events = try? cache.events(from: now, to: to) else { return nil }
        return ConferenceDetector.joinCandidate(in: events, now: now)
    }

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
            if !accounts.accounts.isEmpty { alerts.requestPermission() }
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
