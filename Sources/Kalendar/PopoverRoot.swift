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

            ZStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    if agenda.searchMode {
                        Theme.line.frame(height: 1)
                        AgendaList(model: agenda, sections: agenda.searchResults, extendsAtEnd: false, actions: model)
                    } else if let form = model.newItem.form {
                        // the new-item form, live as the input changes (§5)
                        Theme.line.frame(height: 1)
                        EventEditor(model: form, onAdd: model.addNewItem)
                    } else {
                        MonthHeader(model: model)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 6)
                        MonthGrid(model: agenda, onDoubleClick: model.startNewItem)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 4)
                        SyncNotice(engine: agenda.engine)
                        WriteErrorNotice(writer: model.writer)
                        Theme.line.frame(height: 1)
                        AgendaList(model: agenda, sections: agenda.sections, extendsAtEnd: true, actions: model)
                    }
                }
                if model.showsSuggestions {
                    SuggestionList(model: model)
                }
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
        .onChange(of: model.focusRequest) { inputFocused = true }
        .onAppear { inputFocused = true }
    }

    /// One text field for both typing and search: its text follows the mode, so focus never has to
    /// move to a newly created field.
    @ViewBuilder private var inputRow: some View {
        @Bindable var agenda = agenda
        let searching = agenda.searchMode
        let text = Binding(get: { searching ? agenda.query : model.input },
                           set: { if searching { agenda.query = $0 } else { model.input = $0 } })
        HStack(spacing: 8) {
            if searching {
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
            }
            TextField(searching ? "Search" : "", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .foregroundStyle(Theme.text)
                .focused($inputFocused)
                .onExitCommand { model.escape() }
                .accessibilityLabel(searching ? "Search" : "New event or task")
            if searching || !model.input.isEmpty {
                Button { if searching { model.toggleSearch() } else { model.cancelNewItem() } } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.muted)
                .accessibilityLabel(searching ? "Exit search" : "Clear")
            }
            if !searching {
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
    let model: PopoverModel
    @State private var badgeAnchor: NSView?

    private var agenda: AgendaModel { model.agenda }

    var body: some View {
        HStack(spacing: 6) {
            Text(agenda.displayedMonth.formatted(.dateTime.month(.abbreviated)))
                .foregroundStyle(Theme.text)
            Text(agenda.displayedMonth.formatted(.dateTime.year()))
                .foregroundStyle(Theme.accent)
            // pending invitations (§4.2): opens the Notifications popover
            if !agenda.invitations.isEmpty {
                Button { if let badgeAnchor { model.showNotifications(anchor: badgeAnchor) } } label: {
                    Text("\(agenda.invitations.count)")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 22, minHeight: 22)
                        .background(Theme.bad, in: Circle())
                }
                .buttonStyle(.plain)
                .background(AnchorView(view: $badgeAnchor))
                .accessibilityLabel("\(agenda.invitations.count) invitations")
            }
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

/// The last write that failed (§18.3), until dismissed.
private struct WriteErrorNotice: View {
    let writer: EventWriter

    var body: some View {
        if let error = writer.error {
            HStack(alignment: .top, spacing: 6) {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.bad)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button { writer.clearError() } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.muted)
                    .accessibilityLabel("Dismiss")
            }
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
            .accessibilityLabel("View")
            Spacer()
            CalendarsMenu(model: model)
            Spacer()
            Menu {
                Button("Go to Today") { model.agenda.resetToToday() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("Go to Date…") { model.goToDate() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Divider()
                Button("Delete Item") { if let event = model.selectedEvent { model.delete(event) } }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(model.selectedEvent == nil)
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
            .accessibilityLabel("Actions")
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
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .combine)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Theme.card, in: Capsule())
        }
        .fixedSize()
        .accessibilityLabel("Calendars")
    }
}

/// The suggestion list under the input (§5.2): calendars, people or places for the token being typed.
private struct SuggestionList: View {
    let model: PopoverModel

    private var newItem: NewItemModel { model.newItem }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)
            ForEach(Array(newItem.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                row(suggestion)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(index == newItem.selected ? Theme.accent.opacity(0.25) : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                    .onTapGesture { model.input = newItem.accept(index, in: model.input) }
                    .padding(.horizontal, 4)
            }
        }
        .padding(.bottom, 6)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
        .padding(.horizontal, 8)
        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
    }

    private var title: String {
        switch newItem.trigger?.kind {
        case .calendar: "CALENDARS"
        case .contact: "CONTACTS"
        default: "LOCATION SUGGESTIONS"
        }
    }

    @ViewBuilder private func row(_ s: Suggestion) -> some View {
        switch s {
        case .calendar(let c):
            HStack(spacing: 8) {
                Circle().fill(Color(hex: c.backgroundColor)).frame(width: 8, height: 8)
                Text(c.summary).foregroundStyle(Theme.text)
                Text(c.account).foregroundStyle(Theme.muted).lineLimit(1)
            }
            .font(.system(size: 13))
        case .contact(let c):
            HStack(spacing: 8) {
                Text(String((c.name ?? c.email).prefix(1)).uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 24, height: 24)
                    .background(Theme.line, in: Circle())
                VStack(alignment: .leading, spacing: 0) {
                    Text(c.name ?? c.email).font(.system(size: 13)).foregroundStyle(Theme.text)
                    if c.name != nil { Text(c.email).font(.system(size: 11)).foregroundStyle(Theme.muted) }
                }
            }
        case .place(let title, let subtitle):
            HStack(spacing: 8) {
                Image(systemName: "mappin.circle.fill").foregroundStyle(Theme.bad)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.system(size: 13)).foregroundStyle(Theme.text).lineLimit(1)
                    if !subtitle.isEmpty { Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1) }
                }
            }
        }
    }
}
