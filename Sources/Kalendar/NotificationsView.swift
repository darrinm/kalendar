// The Notifications popover (§6.2): invitations awaiting a reply, each with Maybe / Decline / Accept.
import AppKit
import KalendarCore
import SwiftUI

struct NotificationsView: View {
    let model: PopoverModel

    private var invitations: [EventInstance] { model.agenda.invitations }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("Notifications").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.text)
                HStack {
                    Spacer()
                    Menu {
                        Button("Accept All Invitations") { respondToAll("accepted") }
                        Button("Decline All Invitations") { respondToAll("declined") }
                        Button("Maybe All Invitations") { respondToAll("tentative") }
                    } label: {
                        Image(systemName: "ellipsis.circle").foregroundStyle(Theme.muted)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(invitations.isEmpty)
                    .accessibilityLabel("Respond to all")
                }
            }
            .padding(12)
            if invitations.isEmpty {
                Theme.line.frame(height: 1)
                Text("No invitations")
                    .foregroundStyle(Theme.muted)
                    .padding(20)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(invitations, id: \.key) { event in
                        Theme.line.frame(height: 1)
                        InvitationRow(event: event, model: model)
                    }
                }
            }
            .frame(maxHeight: 480)
            .fixedSize(horizontal: false, vertical: true)
            if let error = model.writer.error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.bad)
                    .padding(12)
            }
        }
        .background(Theme.background)
        .animation(.easeOut(duration: 0.2), value: invitations.map(\.key))
    }

    /// "All" in the ⋯ menu means every listed invitation; each recurring one answers for its
    /// occurrence, since one question per series would be a dialog per row.
    private func respondToAll(_ response: String) {
        for event in invitations { model.writer.respond(event, response: response, scope: .occurrence) }
    }
}

private struct InvitationRow: View {
    let event: EventInstance
    let model: PopoverModel

    private var organizer: String? { event.attendees.first(where: \.organizer)?.email }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Text(String((organizer ?? event.summary).prefix(1)).uppercased())
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 34, height: 34)
                    .background(Theme.card, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.summary).font(.system(size: 15)).foregroundStyle(Theme.text).lineLimit(2)
                    if let organizer { Text("From: \(organizer)").font(.system(size: 12)).foregroundStyle(Theme.muted) }
                    Text(event.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            // the Notifications popover closes, so the detail opens beside the Mini Window (§6.2)
            .onTapGesture { model.openEvent(event, anchor: nil) }
            HStack {
                Button("Maybe") { model.respond(event, "tentative") }
                Spacer()
                Button("Decline") { model.respond(event, "declined") }
                Button("Accept") { model.respond(event, "accepted") }
            }
            .buttonStyle(.bordered)
        }
        .padding(12)
    }
}
