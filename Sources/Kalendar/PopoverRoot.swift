// The Mini Window's content (§4): input row (or search row), month title, grid, agenda list,
// bottom toolbar. The new-item form arrives in milestone 4.
import AppKit
import KalendarCore
import SwiftUI

struct PopoverRoot: View {
    @Bindable var model: PopoverModel
    @FocusState private var inputFocused: Bool

    private var agenda: AgendaModel { model.agenda }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            inputRow
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            if model.accounts.accounts.isEmpty || model.accounts.accounts.contains(where: \.needsReauth) {
                AccountNotices(model: model)
            }

            if agenda.searchMode {
                Theme.line.frame(height: 1)
                AgendaList(model: agenda, sections: agenda.searchResults, extendsAtEnd: false,
                           onOpen: model.openEvent)
            } else {
                MonthHeader(agenda: agenda)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
                MonthGrid(model: agenda)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
                SyncNotice(engine: agenda.engine)
                Theme.line.frame(height: 1)
                AgendaList(model: agenda, sections: agenda.sections, extendsAtEnd: true, onOpen: model.openEvent)
            }

            Spacer(minLength: 0)
            Theme.line.frame(height: 1)
            Toolbar(model: model)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
        .frame(width: PopoverController.size.width, height: PopoverController.size.height)
        .background(Theme.background)
        .tint(Theme.accent)
        // deferred one turn: switching to search swaps in a new text field, which must exist first
        .onChange(of: model.focusRequest) { DispatchQueue.main.async { inputFocused = true } }
        .onAppear { inputFocused = true }
    }

    @ViewBuilder private var inputRow: some View {
        @Bindable var agenda = agenda
        HStack(spacing: 8) {
            if agenda.searchMode {
                Menu {
                    Picker("Search in", selection: $agenda.scope) {
                        ForEach(CalendarCache.SearchScope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .foregroundStyle(Theme.accent)
                .help("Search in \(agenda.scope.rawValue)")
                TextField("Search", text: $agenda.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.text)
                    .focused($inputFocused)
                    .onExitCommand { model.escape() }
                Button { model.toggleSearch() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.muted)
                    .accessibilityLabel("Exit search")
            } else {
                TextField("", text: $model.input)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.text)
                    .focused($inputFocused)
                    .onExitCommand { model.escape() }
                    .accessibilityLabel("New event or task")
                if !model.input.isEmpty {
                    Button { model.input = "" } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.muted)
                        .accessibilityLabel("Clear")
                }
                Button { model.toggleSearch() } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.muted)
                    .help("Search (⌘F)")
                    .accessibilityLabel("Search")
            }
        }
        .font(.system(size: 15))
    }
}

/// "Oct 2026": month in the text color, year in the accent, then ‹ › (§4.2, §14).
private struct MonthHeader: View {
    let agenda: AgendaModel

    var body: some View {
        HStack(spacing: 6) {
            Text(agenda.displayedMonth.formatted(.dateTime.month(.abbreviated)))
                .foregroundStyle(Theme.text)
            Text(agenda.displayedMonth.formatted(.dateTime.year()))
                .foregroundStyle(Theme.accent)
            Spacer()
            Button { agenda.moveMonth(by: -1) } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("Previous month")
            Button { agenda.moveMonth(by: 1) } label: { Image(systemName: "chevron.right") }
                .accessibilityLabel("Next month")
        }
        .font(.system(size: 26, weight: .semibold))
        .buttonStyle(MonthArrowStyle())
    }
}

private struct MonthArrowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Theme.muted.opacity(configuration.isPressed ? 0.5 : 1))
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
    }
}

/// With no account: a sign-in row (§8.5). For each account whose token is dead: "Sign in again".
private struct AccountNotices: View {
    let model: PopoverModel

    var body: some View {
        let accounts = model.accounts.accounts
        if accounts.isEmpty {
            NoticeRow(text: "Kalendar shows your Google Calendar and Google Tasks.",
                      button: "Sign in with Google") { model.signIn(nil) }
        }
        ForEach(accounts.filter(\.needsReauth)) { account in
            NoticeRow(text: "Kalendar can no longer reach \(account.email).",
                      button: "Sign in again") { model.signIn(account.email) }
        }
    }
}

private struct NoticeRow: View {
    let text: String
    let button: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button(button, action: action)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }
}

/// A grey line when the last sync failed: the list shows what the cache had (§18.3).
private struct SyncNotice: View {
    let engine: SyncEngine

    var body: some View {
        if case .failed = engine.state {
            Text("Couldn't reach Google. Showing saved events.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
        }
    }
}

/// ≡ view menu, calendar visibility menu, ⚙ action menu (§4.4).
private struct Toolbar: View {
    let model: PopoverModel

    var body: some View {
        HStack {
            Menu {
                Toggle("Month", isOn: .constant(true))
                    .keyboardShortcut("3", modifiers: .command)
                Divider()
                Button("Tasks") {}.disabled(true)
            } label: {
                ToolbarIcon(systemName: "line.3.horizontal")
            }
            .help("View")
            Spacer()
            CalendarsMenu(model: model)
            Spacer()
            Menu {
                Button("Go to Today") { model.agenda.resetToToday() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("Go to Date…") { model.goToDate() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Divider()
                Button("Refresh All") { model.refresh() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Settings…") { model.showSettings() }
                    .keyboardShortcut(",", modifiers: .command)
                Button("Check for Updates…") { UpdaterController.shared.checkForUpdates() }
                Toggle("Launch at Login", isOn: Binding(get: { LaunchAtLogin.isEnabled }, set: { LaunchAtLogin.set($0) }))
                Divider()
                Button("Quit Kalendar") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            } label: {
                ToolbarIcon(systemName: "gearshape")
            }
            .help("Actions")
        }
        // .button + .plain draws each label as written; .borderlessButton would redraw it as tinted text
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }
}

private struct ToolbarIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 15))
            .foregroundStyle(Theme.muted)
            .frame(width: 30, height: 26)
            .contentShape(Rectangle())
    }
}

/// One checkable row per calendar, grouped by account; writes Google's `selected` (§4.4, §12).
private struct CalendarsMenu: View {
    let model: PopoverModel

    var body: some View {
        let byAccount = Dictionary(grouping: model.agenda.calendars, by: \.account)
        Menu {
            ForEach(byAccount.keys.sorted(), id: \.self) { account in
                Section(account) {
                    ForEach(byAccount[account]!, id: \.key) { calendar in
                        Toggle(calendar.summary, isOn: Binding(
                            get: { calendar.selected },
                            set: { model.setSelected($0, calendar: calendar) }))
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text("Calendars")
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.muted)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Theme.card, in: Capsule())
        }
        .fixedSize()
    }
}
