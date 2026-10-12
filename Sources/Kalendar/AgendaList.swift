// The agenda list (§4.3) and search results (§9): day sections with all-day pills and timed rows.
import AppKit
import KalendarCore
import SwiftUI

struct AgendaList: View {
    let model: AgendaModel
    let sections: [DaySection]
    /// Search results end; the agenda grows when its last section appears.
    let extendsAtEnd: Bool
    let actions: PopoverModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // TimelineView redraws once a minute so "past" dimming and the Join pill stay current
                TimelineView(.everyMinute) { context in
                    let join = model.joinCandidate(now: context.date)
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(sections) { section in
                            DayHeader(day: section.day, today: model.today)
                                .id(section.day)
                            ForEach(section.allDay, id: \.key) { event in
                                AllDayPill(event: event, color: model.color(for: event))
                            }
                            ForEach(section.timed, id: \.key) { event in
                                EventRow(event: event, model: model, now: context.date,
                                         isSelected: model.selectedEvent == event.key,
                                         showsJoin: event.key == join, actions: actions)
                            }
                            if section.isEmpty {
                                Text("No events")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.muted)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 6)
                            }
                        }
                        if extendsAtEnd {
                            Color.clear.frame(height: 1).onAppear { model.extendList() }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
            .onChange(of: model.scrollRequest) {
                guard let target = model.scrollTarget else { return }
                withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(target, anchor: .top) }
            }
            .onAppear {
                if let target = model.scrollTarget { proxy.scrollTo(target, anchor: .top) }
            }
        }
    }
}

private struct DayHeader: View {
    let day: Date
    let today: Date

    var body: some View {
        let (label, date) = Formatting.header(for: day, today: today)
        let isToday = Calendar.current.isDate(day, inSameDayAs: today)
        HStack(spacing: 6) {
            Text(label).fontWeight(.bold)
            Text(date)
        }
        .font(.system(size: 12))
        .foregroundStyle(isToday ? Theme.accent : Theme.muted)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAddTraits(.isHeader)
    }
}

/// All-day events: rounded pills in the event's color, title only (§4.3).
private struct AllDayPill: View {
    let event: EventInstance
    let color: Color

    var body: some View {
        Text(event.summary)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color, in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
            .accessibilityLabel("All day: \(event.summary)")
    }
}

private struct EventRow: View {
    let event: EventInstance
    let model: AgendaModel
    let now: Date
    let isSelected: Bool
    let showsJoin: Bool
    let actions: PopoverModel
    @State private var anchor: NSView?

    var body: some View {
        let past = event.end <= now
        HStack(alignment: .top, spacing: 8) {
            dot.padding(.top, 4)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(Formatting.timeRange(event.start, event.end))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.muted)
                    if event.conferenceURL != nil {
                        Image(systemName: "video.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.muted)
                            .accessibilityLabel("Video call")
                    }
                }
                Text(event.summary)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                if let location = event.location, !location.isEmpty {
                    Text(location)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 4)
            if showsJoin, let link = event.conferenceURL.flatMap(URL.init(string:)) {
                Button("Join") { NSWorkspace.shared.open(link) }
                    .buttonStyle(JoinButtonStyle())
                    .accessibilityLabel("Join \(ConferenceDetector.serviceName(for: link.absoluteString)) meeting")
            }
        }
        .opacity(past ? 0.5 : 1)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(isSelected ? Theme.accent.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .background(AnchorView(view: $anchor))
        .onTapGesture {
            model.selectedEvent = event.key
            actions.openEvent(event, anchor: anchor)
        }
        .contextMenu { EventContextMenu(event: event, actions: actions) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    /// Filled for accepted or own events, open for not-yet-accepted invitations (§4.3).
    @ViewBuilder private var dot: some View {
        let color = model.color(for: event)
        if event.isTentative {
            Circle().strokeBorder(color, lineWidth: 1.5).frame(width: 8, height: 8)
        } else {
            Circle().fill(color).frame(width: 8, height: 8)
        }
    }
}

/// Right-click on an event row (§7.1).
private struct EventContextMenu: View {
    let event: EventInstance
    let actions: PopoverModel

    var body: some View {
        if event.recurringEventId != nil {
            Button("Go to Previous Occurrence") { actions.goToOccurrence(of: event, forward: false) }
            Button("Go to Next Occurrence") { actions.goToOccurrence(of: event, forward: true) }
            Divider()
        }
        if let link = event.conferenceURL, let url = URL(string: link) {
            Button("Join \(ConferenceDetector.serviceName(for: link)) Meeting") { NSWorkspace.shared.open(url) }
            Divider()
        }
        Menu("Color") {
            Button("None") { actions.quickEdit(event) { $0.colorId = nil } }
            ForEach((1...11).map(String.init), id: \.self) { id in
                Button(ColorMenu.names[id]!) { actions.quickEdit(event) { $0.colorId = id } }
            }
        }
        Menu("Show As") {
            Button("Busy") { actions.quickEdit(event) { $0.busy = true } }
            Button("Free") { actions.quickEdit(event) { $0.busy = false } }
        }
        if !event.isInvitation {
            Menu("Visibility") {
                ForEach(["default", "public", "private", "confidential"], id: \.self) { v in
                    Button(v.capitalized) { actions.quickEdit(event) { $0.visibility = v } }
                }
            }
        }
        Divider()
        Button("Copy") { actions.copy(event) }
        Button("Duplicate") { actions.writer.duplicate(event) }
        Button("Duplicate as Task") {}.disabled(true)
        Button("Delete") { actions.delete(event) }
    }
}

private struct JoinButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.7 : 1), in: Capsule())
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
