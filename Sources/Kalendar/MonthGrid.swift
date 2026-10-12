// The month mini-calendar (§4.2): weekday header, six weeks, dots under each day.
import SwiftUI

struct MonthGrid: View {
    let model: AgendaModel
    /// Double-clicking a day starts a new entry on it (§4.2).
    var onDoubleClick: (Date) -> Void = { _ in }

    private var calendar: Calendar { model.calendar }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

    var body: some View {
        let days = model.gridDays
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                ForEach(weekdaySymbols.indices, id: \.self) { i in
                    Text(weekdaySymbols[i])
                        .font(.ui(11, weight: .medium))
                        .foregroundStyle(isTodayColumn(i) ? Theme.accent : Theme.muted)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.bottom, 2)
            ForEach(0..<6, id: \.self) { week in
                let row = Array(days[week * 7..<(week + 1) * 7])
                HStack(spacing: 0) {
                    ForEach(row, id: \.self) { day in
                        DayCell(day: day, model: model, onDoubleClick: onDoubleClick)
                            .frame(maxWidth: .infinity)
                    }
                }
                .background(row.contains(model.selectedDay) ? Theme.line.opacity(0.6) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    /// Weekday initials in the calendar's order, starting on the user's first weekday ("SUN").
    private var weekdaySymbols: [String] {
        let symbols = calendar.shortWeekdaySymbols.map { $0.uppercased() }
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    private func isTodayColumn(_ index: Int) -> Bool {
        (calendar.component(.weekday, from: model.today) - calendar.firstWeekday + 7) % 7 == index
    }
}

private struct DayCell: View {
    let day: Date
    let model: AgendaModel
    let onDoubleClick: (Date) -> Void

    private var calendar: Calendar { model.calendar }

    var body: some View {
        let isToday = calendar.isDate(day, inSameDayAs: model.today)
        let isSelected = calendar.isDate(day, inSameDayAs: model.selectedDay)
        let inMonth = calendar.isDate(day, equalTo: model.displayedMonth, toGranularity: .month)
        let marks = model.marks[day] ?? DayMarks()
        VStack(spacing: 2) {
            Text("\(calendar.component(.day, from: day))")
                .font(.ui(13, weight: isToday ? .semibold : .regular))
                .foregroundStyle(isToday ? .white : inMonth ? Theme.text : Theme.muted)
                .frame(width: 24, height: 24)
                .background {
                    if isToday {
                        Circle().fill(Theme.accent)
                    } else if isSelected {
                        Circle().strokeBorder(Theme.accent, lineWidth: 1.5)
                    }
                }
            HStack(spacing: 2) {
                ForEach(Array(marks.colors.prefix(4).enumerated()), id: \.offset) { _, color in
                    Circle().fill(color).frame(width: 4, height: 4)
                }
                if marks.tasks {
                    Image(systemName: "checkmark").font(.ui(6, weight: .bold)).foregroundStyle(Theme.muted)
                }
            }
            .frame(height: 4)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        // the single click selects at once rather than waiting out the double-click interval
        .gesture(TapGesture(count: 2).onEnded { onDoubleClick(day) })
        .simultaneousGesture(TapGesture().onEnded { model.select(day) })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(isToday: isToday, count: marks.colors.count) + (marks.tasks ? ", tasks due" : ""))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "New item on this day") { onDoubleClick(day) }
    }

    private func accessibilityLabel(isToday: Bool, count: Int) -> String {
        let date = day.formatted(date: .complete, time: .omitted)
        let events = count == 0 ? "no events" : count == 1 ? "1 event" : "\(count) events"
        return (isToday ? "Today, " : "") + "\(date), \(events)"
    }
}
