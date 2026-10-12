// The detail popover for an event (§6), read-only until milestone 3 makes it editable.
import AppKit
import KalendarCore
import SwiftUI

struct EventDetail: View {
    let event: EventInstance
    let model: AgendaModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(event.summary)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            if let location = event.location, !location.isEmpty {
                Text(location).font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            VStack(alignment: .leading, spacing: 4) {
                field("when", when)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    label("calendar")
                    Circle().fill(model.color(for: event)).frame(width: 8, height: 8)
                    Text(model.calendarName(for: event)).foregroundStyle(Theme.text)
                }
                field("show as", event.transparency == "transparent" ? "Free" : "Busy")
            }
            .font(.system(size: 13))
            if let link = event.conferenceURL, let url = URL(string: link) {
                Button("Join \(ConferenceDetector.serviceName(for: link)) Meeting") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.borderedProminent)
            }
            if !event.attendees.isEmpty {
                Theme.line.frame(height: 1)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(event.attendees, id: \.email) { AttendeeRow(attendee: $0) }
                }
            }
            if let notes = event.notes, !notes.isEmpty {
                Theme.line.frame(height: 1)
                Text(plainText(notes))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text)
                    .lineLimit(12)
                    .textSelection(.enabled)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.background)
        .tint(Theme.accent)
    }

    private var when: String {
        if event.allDay {
            let last = Calendar.current.date(byAdding: .day, value: -1, to: event.end)!
            let first = event.start.formatted(date: .abbreviated, time: .omitted)
            return Calendar.current.isDate(event.start, inSameDayAs: last)
                ? "\(first), all day" : (event.start..<last).formatted(date: .abbreviated, time: .omitted)
        }
        return "\(event.start.formatted(date: .abbreviated, time: .omitted)), \(Formatting.timeRange(event.start, event.end))"
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(Theme.muted).frame(width: 64, alignment: .trailing)
    }

    private func field(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            label(name)
            Text(value).foregroundStyle(Theme.text)
        }
    }

    /// Google descriptions can be HTML; show their text.
    private func plainText(_ notes: String) -> String {
        guard notes.contains("<"), let data = notes.data(using: .utf8),
              let attributed = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html,
                                                                             .characterEncoding: String.Encoding.utf8.rawValue],
                                                       documentAttributes: nil)
        else { return notes }
        return attributed.string
    }
}

private struct AttendeeRow: View {
    let attendee: Attendee

    var body: some View {
        HStack(spacing: 6) {
            status
            Text(attendee.displayName ?? attendee.email).foregroundStyle(Theme.text)
            if let suffix { Text(suffix).foregroundStyle(Theme.muted) }
        }
        .font(.system(size: 12))
    }

    /// (organizer), (optional), (me, optional) — §6.
    private var suffix: String? {
        var parts: [String] = []
        if attendee.isSelf { parts.append("me") }
        if attendee.organizer { parts.append("organizer") }
        if attendee.optional { parts.append("optional") }
        return parts.isEmpty ? nil : "(\(parts.joined(separator: ", ")))"
    }

    @ViewBuilder private var status: some View {
        switch attendee.responseStatus {
        case "accepted": Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok)
        case "declined": Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.bad)
        case "tentative": Image(systemName: "questionmark.circle.fill").foregroundStyle(Theme.wait)
        default: Image(systemName: "questionmark.circle").foregroundStyle(Theme.muted)
        }
    }
}
