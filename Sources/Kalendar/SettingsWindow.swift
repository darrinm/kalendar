// Settings (§12). Milestone 1 implements General and Accounts; the other tabs exist so the
// window has its final shape.
import AppKit
import KalendarCore
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let accounts: AccountStore
    private let signIn: (String?) -> Void
    private var window: NSWindow?

    init(accounts: AccountStore, signIn: @escaping (String?) -> Void) {
        self.accounts = accounts
        self.signIn = signIn
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(accounts: accounts, signIn: signIn))
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
    let signIn: (String?) -> Void

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            AccountsSettings(accounts: accounts, signIn: signIn)
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
            NotYet()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            NotYet()
                .tabItem { Label("Events & Tasks", systemImage: "list.bullet") }
            NotYet()
                .tabItem { Label("Calendars", systemImage: "calendar") }
        }
        .frame(width: 480, height: 320)
        .tint(Theme.accent)
    }
}

private struct GeneralSettings: View {
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var automaticUpdates = UpdaterController.shared.automaticallyChecks
    @AppStorage("showAlerts") private var showAlerts = true

    var body: some View {
        Form {
            // reads back the actual state, which can differ from the request (approval pending)
            Toggle("Launch at login", isOn: Binding(
                get: { launchAtLogin },
                set: { LaunchAtLogin.set($0); launchAtLogin = LaunchAtLogin.isEnabled }))
            Toggle("Show alerts", isOn: $showAlerts)
            Toggle("Check for updates automatically", isOn: Binding(
                get: { automaticUpdates },
                set: { UpdaterController.shared.automaticallyChecks = $0; automaticUpdates = $0 }))
                .disabled(!UpdaterController.shared.isAvailable)
        }
        .formStyle(.grouped)
    }
}

private struct AccountsSettings: View {
    let accounts: AccountStore
    let signIn: (String?) -> Void

    var body: some View {
        Form {
            Section {
                if accounts.accounts.isEmpty {
                    Text("No Google accounts").foregroundStyle(.secondary)
                }
                ForEach(accounts.accounts) { account in
                    AccountSettingsRow(account: account, accounts: accounts, signIn: signIn)
                }
            }
            Button("Add Account…") { signIn(nil) }
        }
        .formStyle(.grouped)
    }
}

private struct AccountSettingsRow: View {
    let account: AccountStore.Account
    let accounts: AccountStore
    let signIn: (String?) -> Void
    @State private var status = ""

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
        .task(id: account) {
            guard !account.needsReauth else { return }
            status = "Checking…"
            status = await accounts.calendarCountText(for: account.email)
        }
    }
}

private struct NotYet: View {
    var body: some View {
        Text("Not available yet.")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
