// Popover content for milestone 1: the input row, the month title, account status rows, and the
// bottom toolbar. The month grid and agenda list arrive in milestone 2.
import AppKit
import KalendarCore
import SwiftUI

struct PopoverRoot: View {
    @Bindable var model: PopoverModel
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("", text: $model.input)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .foregroundStyle(Theme.text)
                .focused($inputFocused)
                .onExitCommand { model.escape() }
                .accessibilityLabel("New event or task")
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            MonthTitle(date: Date())
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

            Theme.line.frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    AccountRows(model: model)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 0)
            Theme.line.frame(height: 1)
            HStack {
                Spacer()
                Button {
                    model.showSettings()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.muted)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(",", modifiers: .command)
                .help("Settings")
                .accessibilityLabel("Settings")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: PopoverController.size.width, height: PopoverController.size.height)
        .background(Theme.background)
        .tint(Theme.accent)
        .onChange(of: model.focusRequest) { inputFocused = true }
        .onAppear { inputFocused = true }
    }
}

/// "Oct 2026": month in the text color, year in the accent (§4.2, §14).
struct MonthTitle: View {
    let date: Date

    var body: some View {
        HStack(spacing: 6) {
            Text(date.formatted(.dateTime.month(.abbreviated)))
                .foregroundStyle(Theme.text)
            Text(date.formatted(.dateTime.year()))
                .foregroundStyle(Theme.accent)
        }
        .font(.system(size: 26, weight: .semibold))
    }
}

/// With no account: one sign-in row (§8.5). With accounts: a "Sign in again" row for each account
/// whose token is dead, then one row per signed-in account. Clicking a signed-in row opens the
/// detail popover beside the Mini Window.
private struct AccountRows: View {
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
        ForEach(accounts.filter { !$0.needsReauth }) { account in
            AccountRow(email: account.email, model: model)
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
                .controlSize(.regular)
        }
        .padding(16)
    }
}

private struct AccountRow: View {
    let email: String
    let model: PopoverModel
    @State private var anchor: NSView?

    var body: some View {
        Button {
            guard let anchor else { return }
            model.showDetail(anchor, AnyView(AccountDetail(email: email, model: model)))
        } label: {
            HStack(spacing: 8) {
                Circle().fill(Theme.accent).frame(width: 8, height: 8)
                Text(email).font(.system(size: 13)).foregroundStyle(Theme.text)
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .background(AnchorView(view: $anchor))
    }
}

/// Detail popover content for an account row. In milestone 3 the same popover shows an event.
private struct AccountDetail: View {
    let email: String
    let model: PopoverModel
    @State private var calendars: String = "Loading calendars…"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(email).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
            Text(calendars).font(.system(size: 13)).foregroundStyle(Theme.muted)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.background)
        .task { calendars = await model.accounts.calendarCountText(for: email) }
    }
}

/// Exposes the NSView behind a SwiftUI view so AppKit can anchor a popover to it.
struct AnchorView: NSViewRepresentable {
    @Binding var view: NSView?

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { view = v }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
