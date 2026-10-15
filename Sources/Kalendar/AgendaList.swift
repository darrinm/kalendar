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
                                AllDayPill(event: event, model: model, isSelected: model.selection == event.key,
                                           actions: actions)
                            }
                            ForEach(section.tasks, id: \.key) { task in
                                TaskRow(task: task, actions: actions)
                            }
                            ForEach(section.timed, id: \.key) { event in
                                EventRow(event: event, model: model, now: context.date,
                                         isSelected: model.selection == event.key,
                                         showsJoin: event.key == join, actions: actions)
                            }
                            if section.isEmpty {
                                Text("No events")
                                    .uiFont(12)
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
            // keyboard selection (§11) keeps the selected row on screen
            .onChange(of: model.selection) {
                if let key = model.selection { proxy.scrollTo(key) }
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
        .uiFont(12)
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
    let model: AgendaModel
    /// Keyboard selection (§11): the row selection color behind the pill.
    let isSelected: Bool
    let actions: PopoverModel

    var body: some View {
        Text(event.summary)
            .uiFont(12, weight: .medium)
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(model.color(for: event), in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .rowSelection(isSelected)
            .padding(.horizontal, 8)
            .modifier(EventClicks(event: event, model: model, actions: actions))
            .accessibilityLabel("All day: \(event.summary)")
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(eventAccessibilityValue(event, isSelected: isSelected))
    }
}

/// VoiceOver's value for an event row or all-day pill: an unanswered invitation, then selection.
private func eventAccessibilityValue(_ event: EventInstance, isSelected: Bool) -> String {
    [event.isUnanswered ? "not answered" : nil, isSelected ? "selected" : nil]
        .compactMap { $0 }.joined(separator: ", ")
}

/// An event row's click (the detail popover, §6) and right-click (§7.1), for timed rows and
/// all-day pills alike.
private struct EventClicks: ViewModifier {
    let event: EventInstance
    let model: AgendaModel
    let actions: PopoverModel
    @State private var anchor: NSView?

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .background(AnchorView(view: $anchor))
            .onTapGesture {
                model.selection = event.key
                actions.openEvent(event, anchor: anchor)
            }
            .contextMenu { EventContextMenu(event: event, actions: actions) }
    }
}

private struct EventRow: View {
    let event: EventInstance
    let model: AgendaModel
    let now: Date
    let isSelected: Bool
    let showsJoin: Bool
    let actions: PopoverModel

    var body: some View {
        // events that ended today are always dimmed (§4.3); earlier days' only with the setting (§12)
        let past = event.end <= now && (event.end > model.today || Preferences.shared.dimPast)
        HStack(alignment: .top, spacing: 8) {
            dot.padding(.top, 4)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(Preferences.shared.showEventEnds ? Formatting.timeRange(event.start, event.end)
                                                           : event.start.formatted(date: .omitted, time: .shortened))
                        .uiFont(12, weight: .medium)
                        .foregroundStyle(Theme.muted)
                    if event.conferenceURL != nil {
                        Image(systemName: "video.fill")
                            .uiFont(9)
                            .foregroundStyle(Theme.muted)
                            .accessibilityLabel("Video call")
                    }
                }
                Text(event.summary)
                    .uiFont(13)
                    .foregroundStyle(event.isUnanswered ? Theme.muted : Theme.text)
                    .lineLimit(2)
                if let location = event.displayLocation {
                    Text(location)
                        .uiFont(11)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 4)
            if showsJoin, let link = event.conferenceURL.flatMap(URL.init(string:)) {
                Button("Join") { Meeting.join(link) }
                    .buttonStyle(JoinButtonStyle())
                    .accessibilityLabel("Join \(ConferenceDetector.serviceName(for: link.absoluteString)) meeting")
            }
        }
        .opacity(past ? 0.5 : 1)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .rowSelection(isSelected)
        .padding(.horizontal, 8)
        .modifier(EventClicks(event: event, model: model, actions: actions))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(eventAccessibilityValue(event, isSelected: isSelected))
        .accessibilityActions {
            if let link = event.conferenceURL.flatMap(URL.init(string:)) {
                Button("Join \(ConferenceDetector.serviceName(for: link.absoluteString)) Meeting") { Meeting.join(link) }
            }
        }
    }

    /// Filled for accepted or own events, open for not-yet-accepted invitations, ⊘ for declined
    /// ones when they are shown (§4.3).
    @ViewBuilder private var dot: some View {
        let color = model.color(for: event)
        if event.isDeclined {
            Image(systemName: "circle.slash").uiFont(9).foregroundStyle(color).frame(width: 8, height: 8)
                .accessibilityLabel("Declined")
        } else if event.isTentative {
            Circle().strokeBorder(color, lineWidth: 1.5).frame(width: 8, height: 8)
                .accessibilityLabel(event.isMaybe ? "Maybe" : "")
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
            Button("Join \(ConferenceDetector.serviceName(for: link)) Meeting") { Meeting.join(url) }
            Divider()
        }
        // a read-only calendar (holidays, a shared calendar) refuses every write
        let writable = actions.agenda.isWritable(event)
        if writable {
            editMenus
            Divider()
        }
        Button("Copy") { actions.copy(event) }
        if writable { Button("Duplicate") { actions.writer.duplicate(event) } }
        Button("Duplicate as Task") { actions.duplicateAsTask(event) }
        if writable { Button("Delete") { actions.delete(event) } }
    }

    @ViewBuilder private var editMenus: some View {
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
    }
}

private struct JoinButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .uiFont(12, weight: .semibold)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.7 : 1), in: Capsule())
    }
}

extension View {
    /// A selected row's background (§14): the accent at 20% behind it.
    func rowSelection(_ selected: Bool) -> some View {
        background(selected ? Theme.accent.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A calendar's color dot (§14).
struct CalendarDot: View {
    let hex: String

    var body: some View {
        Circle().fill(Color(hex: hex)).frame(width: 8, height: 8)
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
