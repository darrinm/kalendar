// The detail popover (§6, §6.1): an event's fields, edited in place. Edits save when it closes.
import AppKit
import KalendarCore
import SwiftUI

struct EventEditor: View {
    @Bindable var model: EventEditorModel
    /// The new-item form's Add Event button (§5.1); nil for an existing event.
    var onAdd: (() -> Void)?

    private var readOnly: Bool { model.isInvitation }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                header
                fields
                if model.expanded || readOnly || !model.draft.attendees.isEmpty { attendees }
                if model.expanded || readOnly { notes }
                WriteError(writer: model.writer)
                if model.isInvitation {
                    RSVPButtons { model.respond($0) }.padding(.top, 6)
                }
                if !readOnly {
                    HStack {
                        Button { model.expanded.toggle() } label: {
                            Image(systemName: model.expanded ? "chevron.up" : "chevron.down")
                                .foregroundStyle(Theme.muted)
                                .frame(width: 24, height: 18)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(model.expanded ? "Fewer fields" : "More fields")
                        if let onAdd {
                            Spacer()
                            Button("Add Event", action: onAdd)
                                .buttonStyle(.borderedProminent)
                                .disabled(!model.canAdd)
                            Spacer()
                            Color.clear.frame(width: 24, height: 18)
                        }
                    }
                }
            }
            .padding(16)
        }
        .frame(maxHeight: 640)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.background)
        .tint(Theme.accent)
        .font(.system(size: 13))
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Title", text: $model.draft.summary, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.text)
                .disabled(readOnly)
            TextField("Add Location", text: $model.draft.location)
                .textFieldStyle(.plain)
                .foregroundStyle(Theme.muted)
                .disabled(readOnly)
            if !model.isNew, let link = model.event.conferenceURL, let url = URL(string: link) {
                Button("Join \(ConferenceDetector.serviceName(for: link)) Meeting") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
    }

    @ViewBuilder private var fields: some View {
        let d = model.draft
        VStack(alignment: .leading, spacing: 6) {
            Row("all-day") {
                Toggle("", isOn: Binding(get: { d.allDay }, set: { model.setAllDay($0) }))
                    .labelsHidden().toggleStyle(.checkbox).disabled(readOnly)
            }
            Row("starts") {
                DatePicker("", selection: Binding(get: { d.start }, set: { model.setStart($0) }),
                           displayedComponents: d.allDay ? [.date] : [.date, .hourAndMinute])
                    .labelsHidden().disabled(readOnly)
            }
            Row("ends") {
                DatePicker("", selection: Binding(get: { model.displayedEnd }, set: { model.displayedEnd = $0 }),
                           in: d.start..., displayedComponents: d.allDay ? [.date] : [.date, .hourAndMinute])
                    .labelsHidden().disabled(readOnly)
            }
            if model.expanded && !d.allDay {
                Row("time zone") { TimeZoneMenu(identifier: $model.draft.timeZone).disabled(readOnly) }
            }
            Row("calendar") { CalendarMenu(model: model) }
            Row("color") { ColorMenu(model: model) }
            if !readOnly {
                Row("repeat") { RepeatMenu(model: model) }
                if let rule = d.recurrence {
                    if rule.preset(start: d.start) == nil {
                        Text(rule.summary(start: d.start)).font(.system(size: 11)).foregroundStyle(Theme.muted)
                            .padding(.leading, labelWidth + 8)
                    }
                    Row("repeat end") { RepeatEndMenu(model: model) }
                }
            }
            AlertRows(model: model)
            Row("show as") {
                Menu(d.busy ? "Busy" : "Free") {
                    Button("Busy") { model.draft.busy = true }
                    Button("Free") { model.draft.busy = false }
                }
                .fixedSize()
            }
            if !readOnly {
                Row("visibility") {
                    Menu(d.visibility.capitalized) {
                        ForEach(["default", "public", "private", "confidential"], id: \.self) { v in
                            Button(v.capitalized) { model.draft.visibility = v }
                        }
                    }
                    .fixedSize()
                }
            }
        }
        .menuStyle(.borderlessButton)
        .foregroundStyle(Theme.text)
    }

    @ViewBuilder private var attendees: some View {
        Theme.line.frame(height: 1)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(model.draft.attendees, id: \.email) { a in
                HStack(spacing: 6) {
                    AttendeeStatus(response: a.responseStatus)
                    Text(a.displayName ?? a.email).foregroundStyle(Theme.text).lineLimit(1)
                    if let suffix = Self.suffix(a) { Text(suffix).foregroundStyle(Theme.muted) }
                    Spacer()
                    if !readOnly && !a.isSelf {
                        Button { model.draft.attendees.removeAll { $0.email == a.email } } label: {
                            Image(systemName: "xmark").font(.system(size: 9))
                        }
                        .buttonStyle(.plain).foregroundStyle(Theme.muted)
                        .accessibilityLabel("Remove \(a.email)")
                    }
                }
                .font(.system(size: 12))
            }
            if !readOnly { AddInvitee(model: model) }
        }
    }

    @ViewBuilder private var notes: some View {
        Theme.line.frame(height: 1)
        if readOnly {
            Text(Self.plainText(model.draft.notes))
                .font(.system(size: 12))
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            TextField("Add Notes", text: $model.draft.notes, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text)
                .lineLimit(3...12)
        }
    }


    /// (organizer), (optional), (me, optional) — §6.
    static func suffix(_ a: Attendee) -> String? {
        var parts: [String] = []
        if a.isSelf { parts.append("me") }
        if a.organizer { parts.append("organizer") }
        if a.optional { parts.append("optional") }
        return parts.isEmpty ? nil : "(\(parts.joined(separator: ", ")))"
    }

    /// Google descriptions can be HTML; show their text.
    static func plainText(_ notes: String) -> String {
        guard notes.contains("<"), let data = notes.data(using: .utf8),
              let attributed = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html,
                                                                             .characterEncoding: String.Encoding.utf8.rawValue],
                                                       documentAttributes: nil)
        else { return notes }
        return attributed.string
    }
}

private let labelWidth: CGFloat = 70

/// A right-aligned grey label and its control (§6 layout).
private struct Row<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(Theme.muted).frame(width: labelWidth, alignment: .trailing)
            content
            Spacer(minLength: 0)
        }
    }
}

struct AttendeeStatus: View {
    let response: String

    var body: some View {
        switch response {
        case "accepted": Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok)
        case "declined": Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.bad)
        case "tentative": Image(systemName: "questionmark.circle.fill").foregroundStyle(Theme.wait)
        default: Image(systemName: "questionmark.circle").foregroundStyle(Theme.muted)
        }
    }
}

// MARK: Field menus

/// Writable calendars grouped by account (§6.1).
private struct CalendarMenu: View {
    let model: EventEditorModel

    var body: some View {
        let current = model.agenda.calendar(forKey: model.draft.calendarKey)
        let byAccount = Dictionary(grouping: model.writableCalendars, by: \.account)
        Menu {
            ForEach(byAccount.keys.sorted(), id: \.self) { account in
                Section(account) {
                    ForEach(byAccount[account]!, id: \.key) { c in
                        Button(c.summary) {
                            model.draft.account = c.account
                            model.draft.calendarId = c.id
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(Color(hex: current?.backgroundColor ?? CalendarInfo.fallbackColor)).frame(width: 8, height: 8)
                Text(current?.summary ?? model.draft.calendarId)
            }
        }
        .fixedSize()
        .disabled(model.isInvitation)
    }
}

/// None (the calendar's color) or one of Google's 11 event colors (§6.1).
struct ColorMenu: View {
    let model: EventEditorModel

    static let names = ["1": "Lavender", "2": "Sage", "3": "Grape", "4": "Flamingo", "5": "Banana", "6": "Tangerine",
                        "7": "Peacock", "8": "Graphite", "9": "Blueberry", "10": "Basil", "11": "Tomato"]

    var body: some View {
        Menu(model.draft.colorId.flatMap { Self.names[$0] } ?? "None") {
            Button("None") { model.draft.colorId = nil }
            Divider()
            ForEach((1...11).map(String.init), id: \.self) { id in
                Button(Self.names[id]!) { model.draft.colorId = id }
            }
        }
        .fixedSize()
    }
}

private struct RepeatMenu: View {
    let model: EventEditorModel
    @State private var showsCustom = false

    var body: some View {
        let rule = model.draft.recurrence
        Menu(rule.map { $0.preset(start: model.draft.start)?.rawValue ?? "Custom" } ?? "None") {
            Button("None") { model.draft.recurrence = nil }
            ForEach(RecurrenceRule.Preset.allCases, id: \.self) { preset in
                Button(preset.rawValue) {
                    var r = preset.rule
                    r.end = rule?.end ?? .never
                    model.draft.recurrence = r
                }
            }
            Divider()
            Button("Custom…") { showsCustom = true }
        }
        .fixedSize()
        .popover(isPresented: $showsCustom, arrowEdge: .trailing) {
            CustomRepeat(rule: rule ?? RecurrenceRule(frequency: .weekly,
                                                      weekdays: [Calendar.current.component(.weekday, from: model.draft.start)])) {
                model.draft.recurrence = $0
                showsCustom = false
            } cancel: { showsCustom = false }
        }
    }
}

/// Custom… (§6.1): frequency, every N, and for a weekly rule the weekdays.
private struct CustomRepeat: View {
    @State var rule: RecurrenceRule
    let done: (RecurrenceRule) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Frequency", selection: $rule.frequency) {
                ForEach(RecurrenceRule.Frequency.allCases, id: \.self) { Text($0.adjective).tag($0) }
            }
            Stepper("Every \(rule.interval) \(rule.frequency.unit)\(rule.interval == 1 ? "" : "s")", value: $rule.interval, in: 1...99)
            if rule.frequency == .weekly {
                HStack(spacing: 4) {
                    ForEach(1...7, id: \.self) { day in
                        let on = rule.weekdays.contains(day)
                        Button(Calendar.current.veryShortWeekdaySymbols[day - 1]) {
                            if on { rule.weekdays.remove(day) } else { rule.weekdays.insert(day) }
                        }
                        .buttonStyle(.plain)
                        .frame(width: 26, height: 26)
                        .background(on ? Theme.accent : Theme.card, in: Circle())
                        .foregroundStyle(on ? .white : Theme.text)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                Button("OK") { done(rule) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 260)
        .onChange(of: rule.frequency) { if rule.frequency != .weekly { rule.weekdays = [] } }
    }
}

/// Never · On date… · After N times (§6.1).
private struct RepeatEndMenu: View {
    let model: EventEditorModel

    var body: some View {
        let end = model.draft.recurrence?.end ?? .never
        HStack(spacing: 6) {
            Menu(Self.title(end)) {
                Button("Never") { set(.never) }
                Button("On Date") {
                    set(.until(Calendar.current.date(byAdding: .month, value: 1, to: model.draft.start)!))
                }
                Button("After Number of Times") { set(.count(10)) }
            }
            .fixedSize()
            switch end {
            case .until(let day):
                DatePicker("", selection: Binding(get: { day }, set: { set(.until($0)) }),
                           in: model.draft.start..., displayedComponents: .date)
                    .labelsHidden()
            case .count(let n):
                Stepper("\(n) times", value: Binding(get: { n }, set: { set(.count($0)) }), in: 1...999)
            case .never:
                EmptyView()
            }
        }
    }

    private func set(_ end: RecurrenceRule.End) { model.draft.recurrence?.end = end }

    static func title(_ end: RecurrenceRule.End) -> String {
        switch end {
        case .never: "Never"
        case .until: "On Date"
        case .count: "After"
        }
    }
}

/// One row per popup alert, ⊕ to add another, at most 5 (§6.1).
private struct AlertRows: View {
    let model: EventEditorModel

    static let options: [(String, Int?)] = [
        ("None", nil), ("At time of event", 0), ("1 minute before", 1), ("5 minutes before", 5),
        ("10 minutes before", 10), ("15 minutes before", 15), ("30 minutes before", 30), ("45 minutes before", 45),
        ("1 hour before", 60), ("2 hours before", 120), ("1 day before", 1440), ("2 days before", 2880),
    ]

    static func title(_ minutes: Int) -> String {
        options.first { $0.1 == minutes }?.0 ?? "\(minutes) minutes before"
    }

    var body: some View {
        let alerts = model.effectiveAlerts
        let rows = alerts.isEmpty ? [nil] : alerts.map(Optional.some)
        ForEach(Array(rows.enumerated()), id: \.offset) { index, minutes in
            HStack(spacing: 8) {
                Text(index == 0 ? "alert" : "").foregroundStyle(Theme.muted).frame(width: labelWidth, alignment: .trailing)
                Menu(minutes.map(Self.title) ?? "None") {
                    ForEach(Self.options, id: \.0) { option in
                        Button(option.0) { set(index: index, to: option.1, in: alerts) }
                    }
                }
                .fixedSize()
                .foregroundStyle(model.draft.reminders.useDefault ? Theme.muted : Theme.text)
                Spacer(minLength: 0)
                if index == 0 && !alerts.isEmpty && alerts.count < 5 {
                    Button { model.setAlerts(alerts + [alerts.last!]) } label: {
                        Image(systemName: "plus.circle").foregroundStyle(Theme.muted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add alert")
                }
            }
        }
    }

    private func set(index: Int, to minutes: Int?, in alerts: [Int]) {
        var list = alerts
        if let minutes {
            if index < list.count { list[index] = minutes } else { list.append(minutes) }
        } else if index < list.count {
            list.remove(at: index)
        }
        model.setAlerts(list)
    }
}

private struct TimeZoneMenu: View {
    @Binding var identifier: String

    /// Built once: about 600 zones, with readable titles.
    private static let zones = TimeZone.knownTimeZoneIdentifiers.map { ($0, $0.replacingOccurrences(of: "_", with: " ")) }

    var body: some View {
        Menu(identifier.replacingOccurrences(of: "_", with: " ")) {
            ForEach(Self.zones, id: \.0) { zone in
                Button(zone.1) { identifier = zone.0 }
            }
        }
        .fixedSize()
    }
}

/// "Add Invitees" (§5.1): an email address per entry. Contact suggestions arrive in milestone 4.
private struct AddInvitee: View {
    let model: EventEditorModel
    @State private var text = ""

    var body: some View {
        TextField("Add Invitees", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(Theme.text)
            .onSubmit {
                let email = text.trimmingCharacters(in: .whitespaces)
                guard email.contains("@"), !model.draft.attendees.contains(where: { $0.email == email }) else { return }
                if model.draft.attendees.isEmpty, let me = model.agenda.calendar(forKey: model.draft.calendarKey) {
                    // the organizer is listed too, as Google does
                    model.draft.attendees.append(Attendee(email: me.account, displayName: nil, isSelf: true,
                                                          organizer: true, optional: false, responseStatus: "accepted"))
                }
                model.draft.attendees.append(Attendee(email: email, displayName: nil, isSelf: false, organizer: false,
                                                      optional: false, responseStatus: "needsAction"))
                text = ""
            }
    }
}

/// Maybe at the leading edge, Decline and Accept trailing (§6, §6.2).
struct RSVPButtons: View {
    let respond: (String) -> Void

    var body: some View {
        HStack {
            Button("Maybe") { respond("tentative") }
            Spacer()
            Button("Decline") { respond("declined") }
            Button("Accept") { respond("accepted") }
        }
        .buttonStyle(.bordered)
    }
}

/// The last write that failed (§18.3), in red.
struct WriteError: View {
    let writer: EventWriter
    var padding: CGFloat = 0

    var body: some View {
        if let error = writer.error {
            Text(error)
                .font(.system(size: 12))
                .foregroundStyle(Theme.bad)
                .fixedSize(horizontal: false, vertical: true)
                .padding(padding)
        }
    }
}
