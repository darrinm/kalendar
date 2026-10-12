// Text formats from §4.3: section headers and time ranges.
import Foundation

enum Formatting {
    private static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("Mdyy")
        return f
    }()
    private static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEE")
        return f
    }()
    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    /// ("TODAY", "10/12/26"), ("TOMORROW", …), ("WEDNESDAY", …)
    static func header(for day: Date, today: Date, calendar: Calendar = .current) -> (String, String) {
        let label: String
        if calendar.isDate(day, inSameDayAs: today) {
            label = "Today"
        } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today), calendar.isDate(day, inSameDayAs: tomorrow) {
            label = "Tomorrow"
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), calendar.isDate(day, inSameDayAs: yesterday) {
            label = "Yesterday"
        } else {
            label = weekday.string(from: day)
        }
        return (label.uppercased(), shortDate.string(from: day))
    }

    /// "9:00 – 10:00 AM", "11:30 AM – 12:30 PM": the AM/PM marker appears once when both ends share it.
    static func timeRange(_ start: Date, _ end: Date) -> String {
        let s = time.string(from: start), e = time.string(from: end)
        let symbols = [time.amSymbol ?? "AM", time.pmSymbol ?? "PM"]
        for symbol in symbols where s.hasSuffix(symbol) && e.hasSuffix(symbol) {
            let trimmed = s.dropLast(symbol.count).trimmingCharacters(in: .whitespaces)
            return "\(trimmed) – \(e)"
        }
        return "\(s) – \(e)"
    }
}
