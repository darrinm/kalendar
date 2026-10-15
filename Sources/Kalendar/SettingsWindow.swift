// Settings (§12): General, Accounts, Appearance, Events & Tasks, Calendars, all kept in Preferences.
import AppKit
import KalendarCore
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let accounts: AccountStore
    private let cache: CalendarCache
    private let engine: SyncEngine
    private let alerts: AlertScheduler
    private let signIn: (String?) -> Void
    private var window: NSWindow?

    init(accounts: AccountStore, cache: CalendarCache, engine: SyncEngine, alerts: AlertScheduler,
         signIn: @escaping (String?) -> Void) {
        self.accounts = accounts
        self.cache = cache
        self.engine = engine
        self.alerts = alerts
        self.signIn = signIn
    }

    /// A standard macOS settings window: the tabs are toolbar items with icons, and the window
    /// resizes to each tab's content.
    func show() {
        if window == nil {
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            for tab in SettingsTab.allCases {
                let pane = NSHostingController(rootView: SettingsPane(
                    tab: tab, accounts: accounts, cache: cache, engine: engine, alerts: alerts, signIn: signIn))
                // the window takes each pane's size from its SwiftUI content
                pane.sizingOptions = .preferredContentSize
                // the window title follows the selected pane's
                pane.title = tab.title
                let item = NSTabViewItem(viewController: pane)
                item.label = tab.title
                item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
                tabs.addTabViewItem(item)
            }
            let window = NSWindow(contentViewController: tabs)
            window.styleMask = [.titled, .closable]
            window.toolbarStyle = .preference
            window.isReleasedWhenClosed = false
            // sizes the window to the first pane before centering; otherwise it centers at its
            // initial 500x588 frame and then shrinks toward its top-left corner when shown
            window.layoutIfNeeded()
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

enum SettingsTab: String, CaseIterable {
    case general = "General", accounts = "Accounts", appearance = "Appearance",
         eventsAndTasks = "Events & Tasks", calendars = "Calendars"

    var title: String { rawValue }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .accounts: "person.crop.circle"
        case .appearance: "paintbrush"
        case .eventsAndTasks: "list.bullet"
        case .calendars: "calendar"
        }
    }
}

/// One tab's content, as tall as its rows. A pane taller than `maxHeight` scrolls (Accounts and
/// Calendars grow with the accounts).
struct SettingsPane: View {
    let tab: SettingsTab
    let accounts: AccountStore
    let cache: CalendarCache
    let engine: SyncEngine
    let alerts: AlertScheduler
    let signIn: (String?) -> Void
    static let width: CGFloat = 520
    static let maxHeight: CGFloat = 560

    var body: some View {
        Group {
            switch tab {
            case .general: GeneralSettings(alerts: alerts, cache: cache, engine: engine)
            case .accounts: AccountsSettings(accounts: accounts, cache: cache, engine: engine, signIn: signIn)
            case .appearance: AppearanceSettings()
            case .eventsAndTasks: EventsAndTasksSettings()
            case .calendars: CalendarsSettings(cache: cache, engine: engine)
            }
        }
        .frame(width: Self.width)
        .frame(maxHeight: Self.maxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .tint(Theme.accent)
    }
}

private struct GeneralSettings: View {
    let alerts: AlertScheduler
    let cache: CalendarCache
    let engine: SyncEngine
    @Bindable private var prefs = Preferences.shared
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var automaticUpdates = UpdaterController.shared.automaticallyChecks
    @State private var calendars: [CalendarInfo] = []
    @State private var lists: [TaskList] = []

    /// "8:00 AM" … for Day starts at.
    private static let hours = (0..<24).map { hour in
        (hour, Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date())!
            .formatted(date: .omitted, time: .shortened))
    }

    var body: some View {
        Form {
            // reads back the actual state, which can differ from the request (approval pending)
            Toggle("Launch at login", isOn: Binding(
                get: { launchAtLogin },
                set: { LaunchAtLogin.set($0); launchAtLogin = LaunchAtLogin.isEnabled }))
            LabeledContent("Global shortcut") { ShortcutRecorder(prefs: prefs) }
            Picker("Default calendar", selection: $prefs.defaultCalendar) {
                Text("Primary calendar").tag(String?.none)
                ForEach(calendars, id: \.key) { Text("\($0.summary) (\($0.account))").tag(Optional($0.key)) }
            }
            Picker("Default task list", selection: $prefs.defaultTaskList) {
                Text("First list").tag(String?.none)
                ForEach(lists, id: \.key) { Text("\($0.title) (\($0.account))").tag(Optional($0.key)) }
            }
            Picker("Default event duration", selection: $prefs.defaultDuration) {
                ForEach([15, 30, 45, 60, 90, 120], id: \.self) { Text($0 < 60 || $0 % 60 != 0 ? "\($0) minutes" : "\($0 / 60) hour\($0 == 60 ? "" : "s")").tag($0) }
            }
            Picker("Start week on", selection: $prefs.firstWeekday) {
                Text("System setting").tag(0)
                ForEach(1...7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0 - 1]).tag($0) }
            }
            Picker("Day starts at", selection: $prefs.dayStartHour) {
                ForEach(Self.hours, id: \.0) { Text($0.1).tag($0.0) }
            }
            Toggle("Play UI sounds", isOn: $prefs.playSounds)
            Toggle("Go to today after adding items", isOn: $prefs.goToTodayAfterAdding)
            Toggle("Show alerts", isOn: $prefs.showAlerts)
            if prefs.showAlerts && !alerts.allowedBySystem {
                HStack {
                    Text("Alerts are off in System Settings")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")")!)
                    }
                }
            }
            Toggle("Check for updates automatically", isOn: Binding(
                get: { automaticUpdates },
                set: { UpdaterController.shared.automaticallyChecks = $0; automaticUpdates = $0 }))
                .disabled(!UpdaterController.shared.isAvailable)
        }
        .formStyle(.grouped)
        // re-read when a sync finishes, so new calendars and lists appear
        .task(id: engine.lastSync) {
            calendars = ((try? cache.calendars()) ?? []).filter(\.isWritable)
            lists = (try? cache.taskLists()) ?? []
        }
        .task { await alerts.refreshPermission() }
        // back from System Settings
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await alerts.refreshPermission() }
        }
    }
}

private struct AppearanceSettings: View {
    @Bindable private var prefs = Preferences.shared

    var body: some View {
        Form {
            Picker("Menu bar icon shows", selection: $prefs.iconStyle) {
                ForEach(Preferences.IconStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Toggle("Use color icon", isOn: $prefs.colorIcon)
            Picker("Text size", selection: $prefs.textSize) {
                ForEach(Preferences.TextSize.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Theme", selection: $prefs.appearance) {
                ForEach(Preferences.Appearance.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        .formStyle(.grouped)
    }
}

private struct EventsAndTasksSettings: View {
    @Bindable private var prefs = Preferences.shared

    var body: some View {
        Form {
            Picker("List shows", selection: $prefs.listDays) {
                Text("Next 7 days").tag(7)
                Text("Next 14 days").tag(14)
                Text("Next 30 days").tag(30)
                Text("All days").tag(0)
            }
            Toggle("Show when events end", isOn: $prefs.showEventEnds)
            Toggle("Show declined events", isOn: $prefs.showDeclined)
            Toggle("Combine identical events", isOn: $prefs.combineIdentical)
            Toggle("Dim items on previous days", isOn: $prefs.dimPast)
            Toggle("Show tasks in list", isOn: $prefs.showTasksInList)
            Toggle("Show completed tasks", isOn: $prefs.showCompletedTasks)
            Picker("Sort tasks by", selection: $prefs.taskSort) {
                ForEach(TaskSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
        }
        .formStyle(.grouped)
    }
}

/// The task-list sections' identity, distinct from the calendar sections', which are also per account.
private struct ListsSection: Identifiable {
    let account: String
    var id: String { "tasks|\(account)" }
}

/// Calendar visibility writes Google's `selected` flag; task-list visibility is local (§12).
private struct CalendarsSettings: View {
    let cache: CalendarCache
    let engine: SyncEngine
    @Bindable private var prefs = Preferences.shared
    /// Toggled calendars whose write is in flight.
    @State private var pending: [String: Bool] = [:]
    @State private var calendars: [String: [CalendarInfo]] = [:]
    @State private var lists: [String: [TaskList]] = [:]

    /// The cache's calendars and lists, by account: after each sync and each visibility write.
    private func load() {
        calendars = Dictionary(grouping: (try? cache.calendars()) ?? [], by: \.account)
        lists = Dictionary(grouping: (try? cache.taskLists()) ?? [], by: \.account)
    }

    var body: some View {
        Form {
            ForEach(calendars.keys.sorted(), id: \.self) { account in
                Section("Calendars: \(account)") {
                    ForEach(calendars[account]!, id: \.key) { calendar in
                        Toggle(isOn: Binding(get: { pending[calendar.key] ?? calendar.selected }, set: { selected in
                            pending[calendar.key] = selected
                            Task {
                                await engine.setVisible(selected, calendar: calendar)
                                load()
                                pending[calendar.key] = nil
                            }
                        })) {
                            HStack {
                                CalendarDot(hex: calendar.backgroundColor)
                                Text(calendar.summary)
                            }
                        }
                    }
                }
            }
            ForEach(lists.keys.sorted().map { ListsSection(account: $0) }) { section in
                let account = section.account
                Section("Task lists: \(account)") {
                    ForEach(lists[account]!, id: \.key) { list in
                        Toggle(list.title, isOn: Binding(
                            get: { !prefs.hiddenTaskLists.contains(list.key) },
                            set: { if $0 { prefs.hiddenTaskLists.remove(list.key) } else { prefs.hiddenTaskLists.insert(list.key) } }))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: engine.lastSync) { load() }
    }
}

private struct AccountsSettings: View {
    @Bindable private var prefs = Preferences.shared
    let accounts: AccountStore
    let cache: CalendarCache
    let engine: SyncEngine
    let signIn: (String?) -> Void

    var body: some View {
        Form {
            Section {
                if accounts.accounts.isEmpty {
                    Text("No Google accounts").foregroundStyle(.secondary)
                }
                ForEach(accounts.accounts) { account in
                    let calendars = calendars(for: account.email)
                    AccountSettingsRow(account: account, accounts: accounts,
                                       status: status(for: account.email, calendars: calendars),
                                       color: Color(hex: calendars.first(where: \.primary)?.backgroundColor
                                           ?? CalendarInfo.fallbackColor),
                                       signIn: signIn)
                }
            }
            Button("Add Account…") { signIn(nil) }
            Section("Video conferencing") {
                Picker("New events", selection: $prefs.defaultVideo) {
                    ForEach(Preferences.Video.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                if prefs.newEventVideo != prefs.defaultVideo {
                    Text("New events start with None until Zoom is connected.")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Zoom") {
                    if Zoom.account.isConnected {
                        Button("Disconnect") { Zoom.account.disconnect() }
                    } else {
                        Button("Connect…") { Zoom.signIn() }
                    }
                }
                Toggle("Open Zoom meetings in browser", isOn: $prefs.zoomInBrowser)
            }
        }
        .formStyle(.grouped)
    }

    /// The account's cached calendars, re-read whenever a sync finishes.
    private func calendars(for email: String) -> [CalendarInfo] {
        _ = engine.lastSync
        return (try? cache.calendars(account: email)) ?? []
    }

    /// The account's calendar and task-list counts.
    private func status(for email: String, calendars: [CalendarInfo]) -> String {
        let n = calendars.count
        if n == 0 { return engine.state == .syncing ? "Syncing…" : "No calendars synced yet" }
        let lists = (try? cache.taskLists().filter { $0.account == email }.count) ?? 0
        return [n == 1 ? "1 calendar" : "\(n) calendars",
                lists == 0 ? nil : lists == 1 ? "1 task list" : "\(lists) task lists"]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

private struct AccountSettingsRow: View {
    let account: AccountStore.Account
    let accounts: AccountStore
    let status: String
    /// The primary calendar's color.
    let color: Color
    let signIn: (String?) -> Void

    var body: some View {
        HStack {
            Text(account.email.prefix(1).uppercased())
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(color))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.email)
                Text(account.needsReauth ? "Needs to sign in again" : status)
                    .font(.caption)
                    .foregroundStyle(account.needsReauth ? .red : .secondary)
            }
            Spacer()
            if account.needsReauth {
                Button("Sign In…") { signIn(account.email) }
            }
            Button("Sign Out") { Task { await accounts.signOut(account.email) } }
        }
    }
}
