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

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(accounts: accounts, cache: cache,
                                                                     engine: engine, alerts: alerts, signIn: signIn))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Kalendar Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    let accounts: AccountStore
    let cache: CalendarCache
    let engine: SyncEngine
    let alerts: AlertScheduler
    let signIn: (String?) -> Void
    @State var tab = 0
    static let size = NSSize(width: 520, height: 460)
    static let tabCount = 5

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings(alerts: alerts, cache: cache, engine: engine)
                .tabItem { Label("General", systemImage: "gearshape") }.tag(0)
            AccountsSettings(accounts: accounts, cache: cache, engine: engine, signIn: signIn)
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }.tag(1)
            AppearanceSettings()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }.tag(2)
            EventsAndTasksSettings()
                .tabItem { Label("Events & Tasks", systemImage: "list.bullet") }.tag(3)
            CalendarsSettings(cache: cache, engine: engine)
                .tabItem { Label("Calendars", systemImage: "calendar") }.tag(4)
        }
        .frame(width: Self.size.width, height: Self.size.height)
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
                    AccountSettingsRow(account: account, accounts: accounts, status: status(for: account.email), signIn: signIn)
                }
            }
            Button("Add Account…") { signIn(nil) }
        }
        .formStyle(.grouped)
    }

    /// The account's calendar count from the cache, re-read whenever a sync finishes.
    private func status(for email: String) -> String {
        _ = engine.lastSync
        let n = (try? cache.calendars(account: email).count) ?? 0
        if n == 0 { return engine.state == .syncing ? "Syncing…" : "No calendars synced yet" }
        return n == 1 ? "1 calendar" : "\(n) calendars"
    }
}

private struct AccountSettingsRow: View {
    let account: AccountStore.Account
    let accounts: AccountStore
    let status: String
    let signIn: (String?) -> Void

    var body: some View {
        HStack {
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
